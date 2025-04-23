class AudioStreamChannel < ApplicationCable::Channel
  def subscribed
    @session_id = params[:session_id] || SecureRandom.uuid # Get session ID from params or generate a new one
    logger.info "<<< AudioStreamChannel attempting subscription for #{@session_id} >>>"

    if @session_id
      stream_from "audio_stream_channel_#{@session_id}"
      logger.info "<<< AudioStreamChannel SUBSCRIBED for session: #{@session_id} >>>"
      # Acknowledge successful subscription to the client
      logger.info "<<< Preparing to transmit confirm_subscription for #{@session_id} >>>"
      transmit({ type: 'confirm_subscription', message: 'Successfully connected', sessionId: @session_id })
      logger.info "<<< Transmitted confirm_subscription for #{@session_id} >>>"
      
      # Initialize Nova Sonic client and session
      begin
        setup_nova_sonic_session
      rescue => e
        logger.error "Failed to setup Nova Sonic session: #{e.message}"
        logger.error e.backtrace.join("\n")
        transmit({ type: 'error', message: 'Failed to initialize speech service', details: e.message })
      end
    else
      logger.error "Rejected subscription: missing session_id"
      reject_subscription # Reject if no session ID
    end
  end

  def unsubscribed
    logger.info "Unsubscribed: #{@session_id}"
    cleanup_nova_sonic_session
    stop_all_streams
  end

  def receive(data)
    # Handle the WebSocket message format
    message_data = if data.is_a?(String)
      begin
        parsed = JSON.parse(data)
        logger.debug "Parsed string message: #{parsed.inspect}"
        parsed
      rescue JSON::ParserError => e
        logger.error "Failed to parse WebSocket message: #{e.message}"
        transmit({ type: 'error', message: 'Invalid message format' })
        return
      end
    else
      data
    end

    # Extract the actual message data if it's nested in a data field
    if message_data['data'].present?
      begin
        message_data = JSON.parse(message_data['data'])
        logger.debug "Parsed nested data: #{message_data.inspect}"
      rescue JSON::ParserError => e
        logger.error "Failed to parse nested data: #{e.message}"
        transmit({ type: 'error', message: 'Invalid nested data format' })
        return
      end
    end

    return unless message_data['session_id'] == @session_id
    
    case message_data['type']
    when 'prompt_start'
      logger.info "Processing prompt_start for session #{@session_id}"
      @session&.end_prompt
    when 'system_prompt'
      logger.info "Processing system_prompt for session #{@session_id}"
      setup_system_prompt(message_data['content'])
    when 'audio_start'
      logger.info "Processing audio_start for session #{@session_id}"
      # Always try to establish a fresh session for audio_start
      begin
        if @session.nil? || @nova_sonic_client.nil?
          logger.info "No active session found for audio_start, creating new session"
          setup_nova_sonic_session
        end
        setup_audio_start
        transmit({ type: 'audio_started', message: 'Audio streaming initialized' })
      rescue => e
        logger.error "Failed to start audio session: #{e.message}"
        
        # Force a complete reset of the session
        @session = nil
        @nova_sonic_client = nil
        
        # Try one more time with a clean session
        begin
          logger.info "Retrying session creation after failure"
          setup_nova_sonic_session
          setup_audio_start
          transmit({ type: 'audio_started', message: 'Audio streaming initialized on retry' })
        rescue => retry_error
          logger.error "Retry failed for audio_start: #{retry_error.message}"
          transmit({ type: 'error', message: 'Failed to start audio session', details: retry_error.message })
        end
      end
    when 'audio_input'
      if message_data['audio_data'].present?
        # Check if we need to recreate the session
        if @session.nil? || @nova_sonic_client.nil?
          logger.info "No active session for audio_input, recreating session"
          begin
            setup_nova_sonic_session
            # Give the session a moment to initialize
            sleep(0.5)
            # Start audio after recreating the session
            setup_audio_start
            transmit({ type: 'session_recreated', message: 'Session was recreated automatically' })
          rescue => e
            logger.error "Failed to recreate session: #{e.message}"
            transmit({ type: 'error', message: 'Failed to recreate session', details: e.message })
            return
          end
        end
        
        # Strip the data URL prefix if present
        audio_data = message_data['audio_data']
        if audio_data.start_with?('data:')
          logger.debug "Stripping data URL prefix from audio data"
          audio_data = audio_data.split(',', 2).last
        end
        
        # Check if we need to restart audio streaming
        begin
          stream_audio(audio_data)
        rescue => e
          if e.message.include?("ValidationException") || 
             e.message.include?("Connection is closed due to errors")
            
            logger.warn "Validation error during audio streaming, attempting recovery"
            
            # Reset session and try again
            @session = nil
            @nova_sonic_client = nil
            
            # Try to recreate and resume
            begin
              setup_nova_sonic_session
              setup_audio_start
              stream_audio(audio_data) # Try again with same audio
              transmit({ type: 'session_recovered', message: 'Audio session was recovered' })
            rescue => recovery_error
              logger.error "Failed to recover session: #{recovery_error.message}"
              transmit({ type: 'error', message: 'Failed to recover audio session', details: recovery_error.message })
            end
          else
            # Pass through other errors
            raise e
          end
        end
      else
        logger.error "Received empty audio data for session #{@session_id}"
        transmit({ type: 'error', message: 'Empty audio data received' })
      end
    when 'stop_audio'
      logger.info "Processing stop_audio for session #{@session_id}"
      cleanup_nova_sonic_session
    else
      logger.error "Unknown message type for session #{@session_id}: #{message_data['type']}"
      transmit({ type: 'error', message: "Unknown message type: #{message_data['type']}" })
    end
  rescue => e
    logger.error "Error processing message: #{e.message}"
    logger.error e.backtrace.join("\n")
    transmit({ type: 'error', message: 'Error processing message', details: e.message })
  end

  private

  def setup_nova_sonic_session
    # Add credential validation logging
    aws_credentials = {
      access_key_id: ENV['AWS_ACCESS_KEY_ID'],
      secret_access_key: ENV['AWS_SECRET_ACCESS_KEY'],
      session_token: ENV['AWS_SESSION_TOKEN']
    }
    
    # Check if credentials are present
    logger.info "AWS Access Key ID present: #{aws_credentials[:access_key_id].present?}"
    logger.info "AWS Secret Access Key present: #{aws_credentials[:secret_access_key].present?}"
    logger.info "AWS Session Token present: #{aws_credentials[:session_token].present?}"
    
    if aws_credentials[:session_token].present?
      # If using session token, verify token expiration if possible
      begin
        # Dummy STS call to verify credentials (optional)
        require 'aws-sdk-core'
        sts = Aws::STS::Client.new(region: 'us-east-1', credentials: Aws::Credentials.new(
          aws_credentials[:access_key_id],
          aws_credentials[:secret_access_key],
          aws_credentials[:session_token]
        ))
        identity = sts.get_caller_identity
        logger.info "AWS credentials validated successfully. Account: #{identity.account}, ARN: #{identity.arn}"
      rescue StandardError => e
        logger.warn "AWS credential validation failed: #{e.message}"
        transmit({ type: 'error', message: 'AWS credentials may have expired', details: e.message })
        raise "AWS credentials validation error: #{e.message}"
      end
    end
    
    # Create client with a rescue block to catch initialization errors
    begin
      # If we already have a client, try to use it
      if @nova_sonic_client.nil?
        @nova_sonic_client = NovaSonicBidirectionalStreamClient.new(
          region: 'us-east-1',
          credentials: aws_credentials
        )
      end
      
      # Clean up any existing session to avoid conflicts
      if @session
        logger.info "Cleaning up existing session #{@session_id}"
        begin
          @session.close rescue nil
        rescue => e
          logger.warn "Error closing existing session: #{e.message}"
        end
        @session = nil
      end
      
      # Create a new session
      @session = @nova_sonic_client.create_stream_session(@session_id)
      
      # Set up event handlers
      setup_event_handlers
      
      # Initialize the session with a retry mechanism
      initialize_with_retry(3)
    rescue => e
      logger.error "Error initializing Nova Sonic client: #{e.message}"
      logger.error e.backtrace.join("\n")
      transmit({ type: 'error', message: 'Failed to initialize speech service', details: e.message })
      raise
    end
  end
  
  def initialize_with_retry(max_retries = 3)
    attempt = 0
    last_error = nil
    
    while attempt < max_retries
      attempt += 1
      
      begin
        logger.info "Initialize session attempt #{attempt}/#{max_retries}"
        initialize_nova_sonic_session
        
        # If we get here, initialization succeeded
        logger.info "Session initialization successful on attempt #{attempt}"
        return
      rescue => e
        last_error = e
        logger.error "Error during initialization attempt #{attempt}: #{e.message}"
        
        # Only sleep between retries if we're going to retry
        if attempt < max_retries
          sleep_time = [1.0 * attempt, 3.0].min  # Backoff, but max 3 seconds
          logger.info "Waiting #{sleep_time} seconds before retry..."
          sleep(sleep_time)
        end
      end
    end
    
    # If we get here, all attempts failed
    logger.error "Failed to initialize after #{max_retries} attempts"
    if last_error
      logger.error "Last error: #{last_error.message}"
      transmit({ type: 'error', message: 'Failed to initialize session after multiple attempts', details: last_error.message })
      raise last_error
    end
  end
  
  def initialize_nova_sonic_session
    # With our updated initiate_session function, these calls are no longer necessary here
    # The initiate_session method will call these in the correct order
    # The only thing we need to do is initiate the session
    @nova_sonic_client.initiate_session(@session_id)
  end
  
  def setup_system_prompt(content)
    return unless @session
    
    # If a custom system prompt is provided, send it
    if content.present?
      @nova_sonic_client.setup_system_prompt_event(@session_id, nil, content)
      transmit({ type: 'system_prompt_set', message: 'System prompt configured' })
    else
      transmit({ type: 'error', message: 'Empty system prompt content' })
    end
  end
  
  def setup_audio_start
    return unless @session
    
    @nova_sonic_client.setup_start_audio_event(@session_id)
  end

  def setup_event_handlers
    @session.on_event('textOutput') do |data|
      # Handle both direct and nested event formats
      processed_data = if data.is_a?(Hash) && data['event'] && data['event']['textOutput']
        # Extract the nested event data
        { type: 'textOutput', data: { event: { textOutput: data['event']['textOutput'] } } }
      else
        # Already in the expected format
        { type: 'textOutput', data: data }
      end
      transmit(processed_data)
    end

    @session.on_event('audioOutput') do |data|
      # Handle both direct and nested event formats
      processed_data = if data.is_a?(Hash) && data['event'] && data['event']['audioOutput']
        # Extract the nested event data
        { type: 'audioOutput', data: { event: { audioOutput: data['event']['audioOutput'] } } }
      else
        # Already in the expected format
        { type: 'audioOutput', data: data }
      end
      transmit(processed_data)
    end

    @session.on_event('error') do |data|
      # Extract error message from various possible formats
      error_message = nil
      error_details = nil

      if data.is_a?(Hash)
        if data['event'] && data['event']['error']
          # Nested event error format
          error_message = data['event']['error']['message'] rescue "Unknown error"
          error_details = data['event']['error']['details'] rescue nil
        elsif data['message']
          # Direct error message
          error_message = data['message']
          error_details = data['details']
        elsif data['error']
          # Error field
          error_message = data['error']
          error_details = data['source']
        else
          # Fallback
          error_message = "Unknown error from Bedrock"
          error_details = data.to_s
        end
      else
        # Non-hash format
        error_message = "Error occurred: #{data}"
      end

      transmit({ 
        type: 'error', 
        message: error_message,
        details: error_details
      })
    end

    @session.on_event('toolUse') do |data|
      # Handle both direct and nested event formats
      processed_data = if data.is_a?(Hash) && data['event'] && data['event']['toolUse']
        # Extract the nested event data
        { type: 'toolUse', data: { event: { toolUse: data['event']['toolUse'] } } }
      else
        # Already in the expected format
        { type: 'toolUse', data: data }
      end
      transmit(processed_data)
    end

    @session.on_event('toolResult') do |data|
      # Handle both direct and nested event formats
      processed_data = if data.is_a?(Hash) && data['event'] && data['event']['toolResult']
        # Extract the nested event data
        { type: 'toolResult', data: { event: { toolResult: data['event']['toolResult'] } } }
      else
        # Already in the expected format
        { type: 'toolResult', data: data }
      end
      transmit(processed_data)
    end

    @session.on_event('contentEnd') do |data|
      # Handle both direct and nested event formats
      processed_data = if data.is_a?(Hash) && data['event'] && data['event']['contentEnd']
        # Extract the nested event data
        { type: 'contentEnd', data: { event: { contentEnd: data['event']['contentEnd'] } } }
      else
        # Already in the expected format
        { type: 'contentEnd', data: data }
      end
      transmit(processed_data)
    end
    
    @session.on_event('contentStart') do |data|
      # Handle both direct and nested event formats
      processed_data = if data.is_a?(Hash) && data['event'] && data['event']['contentStart']
        # Extract the nested event data
        { type: 'contentStart', data: { event: { contentStart: data['event']['contentStart'] } } }
      else
        # Already in the expected format
        { type: 'contentStart', data: data }
      end
      transmit(processed_data)
    end
    
    @session.on_event('chunk') do |data|
      # Process chunk data which may contain various event types
      # This handles raw chunk events from Bedrock
      logger.debug "Received chunk event: #{data.inspect}"
      
      # Extract and decode the bytes if present
      if data.is_a?(Hash) && data['bytes']
        begin
          decoded_bytes = Base64.decode64(data['bytes'])
          parsed_data = JSON.parse(decoded_bytes)
          logger.debug "Decoded chunk data: #{parsed_data.inspect}"
          
          # Forward the decoded data to frontend
          transmit({ 
            type: 'chunk', 
            data: parsed_data 
          })
          
          # If this chunk contains specific events we already handle, process them directly
          if parsed_data['event']
            event_type = parsed_data['event'].keys.first
            logger.debug "Chunk contains event type: #{event_type}"
            
            # Extract the specific event data
            event_data = { 'event' => parsed_data['event'] }
            
            # Process specific event types if needed
            case event_type
            when 'textOutput'
              # For text outputs inside chunks, we might want to forward directly
              transmit({ type: 'textOutput', data: event_data })
            when 'contentEnd'
              # Special handling for contentEnd events
              transmit({ type: 'contentEnd', data: event_data })
            end
          end
        rescue => e
          logger.error "Error processing chunk data: #{e.message}"
          logger.error "Original chunk data: #{data.inspect}"
        end
      else
        # Forward the raw chunk
        transmit({ type: 'chunk', data: data })
      end
    end

    # Catch-all for any unhandled event types
    @session.on_event('any') do |data|
      if data.is_a?(Hash) && data[:type] && !['textOutput', 'audioOutput', 'error', 'toolUse', 'toolResult', 'contentEnd', 'contentStart', 'chunk'].include?(data[:type])
        logger.info "Received unhandled event type: #{data[:type]}"
        transmit({ type: data[:type], data: data[:data] })
      end
    end
  end

  def stream_audio(audio_data)
    return unless @session
    
    begin
      #logger.info "Processing audio data for session #{@session_id}"
      
      # Log incoming data format/size
      #logger.debug "Raw audio data length: #{audio_data.length} characters"
      #logger.debug "Audio data format check: starts with data:audio prefix? #{audio_data.start_with?('data:audio') ? 'yes' : 'no'}"
      
      # Convert base64 string to binary data
      begin
        audio_buffer = Base64.decode64(audio_data)
        #logger.debug "Base64 decode successful, got #{audio_buffer.bytesize} bytes"
      rescue => e
        logger.error "Base64 decode failed: #{e.message}"
        transmit({ type: 'error', message: 'Failed to decode audio data', details: e.message })
        return
      end
      
      if audio_buffer.empty?
        logger.error "Decoded audio buffer is empty for session #{@session_id}"
        transmit({ 
          type: 'error',
          message: 'Empty audio buffer after decoding'
        })
        return
      end
      
      # Do some basic PCM validation
      if audio_buffer.bytesize < 44  # At least a minimal PCM header size
        logger.warn "Audio buffer may be too small (#{audio_buffer.bytesize} bytes)"
      end
      
      # Further analysis of the decoded buffer
      #logger.debug "Streaming #{audio_buffer.size} bytes of audio data"
      sample_bytes = [audio_buffer[0..15].unpack('C*')].flatten.map{|b| b.to_s(16).rjust(2, '0')}.join(' ')
      #logger.debug "Audio buffer first 16 bytes (hex): #{sample_bytes}"
      
      # Check if the data looks like expected 16kHz, 16-bit PCM (very rough check)
      if audio_buffer.bytesize % 2 != 0
        logger.warn "Audio data length (#{audio_buffer.bytesize}) is not a multiple of 2 bytes - may not be 16-bit PCM"
      end
      
      # Check for WAV header and skip it if present
      if audio_buffer.bytesize >= 44 && audio_buffer[0..3] == "RIFF" && audio_buffer[8..11] == "WAVE"
        logger.info "Found WAV header, attempting to extract PCM data"
        
        # Extract PCM data (skipping the WAV header)
        data_offset = 44  # Standard WAV header size
        audio_buffer = audio_buffer[data_offset..-1]
        logger.info "Extracted #{audio_buffer.bytesize} bytes of PCM data from WAV"
      end
      
      # We'll transmit a processing notification to let the client know we're handling the audio
      # transmit({
      #   type: 'audio_processing',
      #   message: 'Processing audio data',
      #   size: audio_buffer.size,
      #   format: 'audio/lpcm'
      # })
      
      # Stream the audio data to AWS
      begin
        # For this debugging session, let's log the format used in the example
        #logger.debug "Using audio format: audio/lpcm, 16kHz, 16-bit, mono"
        
        # Stream the audio data
        @session.stream_audio(audio_buffer)
        #logger.debug "Audio data successfully sent to streaming session"
      rescue => stream_error
        logger.error "Error streaming audio to session: #{stream_error.message}"
        logger.error stream_error.backtrace.join("\n")
        
        # Handle validation errors specifically
        if stream_error.message.include?("ValidationException") || 
           stream_error.message.include?("Connection is closed due to errors") ||
           stream_error.is_a?(Aws::BedrockRuntime::Types::ValidationException)
          
          handle_session_validation_error(stream_error.message)
          return
        end
        
        # For other errors, attempt standard session restart
        logger.info "Attempting to restart the session after error"
        cleanup_nova_sonic_session
        transmit({ 
          type: 'error',
          message: 'Error streaming audio to AWS, session will be reset',
          details: stream_error.message 
        })
      end
      
    rescue ArgumentError => e
      logger.error "Invalid base64 audio data for session #{@session_id}: #{e.message}"
      transmit({ 
        type: 'error',
        message: 'Invalid audio data format',
        details: e.message 
      })
    rescue => e
      logger.error "Error processing audio for session #{@session_id}: #{e.message}"
      logger.error e.backtrace.join("\n")
      transmit({ 
        type: 'error',
        message: 'Error processing audio',
        details: e.message 
      })
    end
  end

  def cleanup_nova_sonic_session
    return unless @session && @nova_sonic_client # Check both exist

    begin
      # Only explicitly end the current audio content block if needed.
      # The input stream itself remains open for continuous interaction.
      @session.end_audio_content # Send contentEnd for the last audio segment
      logger.info "Requested cleanup for session #{@session_id}: Sent contentEnd for last audio block."
    rescue => e
      logger.error "Error during session cleanup request for #{@session_id}: #{e.message}"
      # If we get a validation exception, we need to recreate the session
      if e.message.include?("ValidationException") || e.message.include?("Connection is closed due to errors")
        logger.info "Detected validation exception, will recreate session on next interaction"
        # Force session recreation on next interaction
        @session = nil
        @nova_sonic_client = nil
      end
    end
  end

  # Add a method to handle session recovery after validation errors
  def handle_session_validation_error(error_message)
    logger.warn "Validation error occurred: #{error_message}"
    
    # Force session cleanup
    begin
      if @session
        @session.close rescue nil
      end
    rescue => e
      logger.warn "Error during forced session cleanup: #{e.message}"
    ensure
      # Make sure we reset these references
      @session = nil
      @nova_sonic_client = nil
    end
    
    # Send error notification to client
    transmit({ 
      type: 'error',
      message: 'Speech session needs to be restarted',
      details: 'The connection with AWS Bedrock speech service was interrupted. Please try speaking again.'
    })
  end
end 