class AudioStreamChannel < ApplicationCable::Channel
  def subscribed
    @session_id = params[:session_id] || SecureRandom.uuid # Get session ID from params or generate a new one
    
    # Log session creation
    logger.info "Subscribing to AudioStreamChannel with session ID: #{@session_id}"
    
    # Setup stream
    stream_from "audio_stream_#{@session_id}"
    
    # Initialize sessions hash if it doesn't exist
    @@sessions ||= {}
    
    # Store the session ID and channel for later use
    @@sessions[@session_id] = self
    
    # Set up initial state
    @nova_sonic_client = nil
    @session = nil
    
    # Setup Nova Sonic session
    begin
      setup_nova_sonic_session
    rescue => e
      logger.error "Error setting up Nova Sonic session: #{e.message}"
      transmit({ type: 'error', message: 'Error setting up Nova Sonic session' })
    end
    
    # Confirm subscription
    transmit({ type: 'connected', session_id: @session_id })
  end

  def unsubscribed
    logger.info "Unsubscribed: #{@session_id}"
    # Clean up Nova Sonic session
    cleanup_nova_sonic_session
    
    # Remove session from sessions hash
    @@sessions.delete(@session_id) if @@sessions
  end

  def receive(data)
    # Handle the WebSocket message format
    message_data = if data.is_a?(String)
      begin
        JSON.parse(data)
      rescue JSON::ParseError => e
        logger.error "Failed to parse incoming message: #{e.message}"
        { 'type' => 'error', 'message' => 'Invalid JSON format' }
      end
    else
      data
    end
    
    begin
      case message_data['type']
      when 'ping'
        transmit({ type: 'pong', timestamp: Time.now.to_i })
      when 'system_prompt'
        logger.info "Processing system_prompt for session #{@session_id}"
        setup_system_prompt(message_data['content'])
      when 'audio_data'
        #logger.info "Processing audio_data for session #{@session_id}"
        audio_data = message_data['audio']
        
        # Skip processing if empty audio data
        if audio_data && !audio_data.empty?
          # Strip data URL prefix if present
          if audio_data.start_with?('data:')
            logger.debug "Stripping data URL prefix from audio data"
            audio_data = audio_data.split(',', 2).last
          end
          
          # Check if we need to restart audio streaming
          begin
            stream_audio(audio_data)
          rescue => e
            if e.message.include?("ValidationException") || 
               e.message.include?("Connection is closed due to errors") ||
               e.message.include?("Session") && e.message.include?("not found or inactive")
              
              logger.warn "Validation error during audio streaming, attempting recovery: #{e.message}"
              
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
      
      # Create a new session - Use the existing session ID consistently
      logger.info "Creating new session with ID: #{@session_id}"
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
        logger.info "Initialize session attempt #{attempt}/#{max_retries} for session ID: #{@session_id}"
        initialize_nova_sonic_session
        
        # If we get here, initialization succeeded
        logger.info "Session initialization successful on attempt #{attempt}"
        
        # Verify the session is actually active
        if @nova_sonic_client && @nova_sonic_client.is_session_active(@session_id)
          logger.info "Session #{@session_id} verified as active"
          transmit({ type: 'session_ready', message: 'Session initialized successfully' })
          return true
        else
          logger.warn "Session #{@session_id} reports as inactive after initialization, will retry"
          raise "Session inactive after initialization"
        end
      rescue => e
        last_error = e
        error_message = e.message
        logger.error "Error during initialization attempt #{attempt}: #{error_message}"
        
        # Force session cleanup to ensure we start fresh
        if @session
          begin
            @session.close rescue nil
          rescue => cleanup_error
            logger.warn "Error during session cleanup: #{cleanup_error.message}"
          ensure
            @session = nil
          end
        end
        
        # Recreate client on the next attempt
        @nova_sonic_client = nil
        
        # Only sleep between retries if we're going to retry
        if attempt < max_retries
          sleep_time = [1.0 * (2 ** attempt), 5.0].min  # Backoff, but max 5 seconds
          logger.info "Waiting #{sleep_time} seconds before retry..."
          sleep(sleep_time)
        end
      end
    end
    
    # If we get here, all attempts failed
    logger.error "Failed to initialize after #{max_retries} attempts"
    if last_error
      logger.error "Last error: #{last_error.message}"
      transmit({ 
        type: 'error', 
        message: 'Failed to initialize session after multiple attempts', 
        details: last_error.message,
        recovery_action: 'refresh_page'
      })
    end
    
    false
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
      # Convert base64 string to binary data
      begin
        audio_buffer = Base64.decode64(audio_data)
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
      
      # Check for WAV header and skip it if present
      if audio_buffer.bytesize >= 44 && audio_buffer[0..3] == "RIFF" && audio_buffer[8..11] == "WAVE"
        logger.info "Found WAV header, extracting PCM data"
        
        # Extract PCM data (skipping the WAV header)
        data_offset = 44  # Standard WAV header size
        audio_buffer = audio_buffer[data_offset..-1]
        logger.info "Extracted #{audio_buffer.bytesize} bytes of PCM data from WAV"
      end
      
      # Ensure the buffer size is even (for 16-bit samples)
      if audio_buffer.bytesize % 2 != 0
        logger.warn "Audio buffer has odd number of bytes (#{audio_buffer.bytesize}), padding with zero"
        audio_buffer += "\x00"
      end
      
      # Verify the audio buffer isn't too small or too large
      if audio_buffer.bytesize < 320  # Less than 10ms of audio at 16kHz
        logger.warn "Audio buffer might be too small (#{audio_buffer.bytesize} bytes)"
      elsif audio_buffer.bytesize > 64000  # More than 2 seconds at 16kHz
        logger.warn "Audio buffer is large (#{audio_buffer.bytesize} bytes), might exceed API limits"
      end
      
      # Stream the audio data to AWS
      max_retry_attempts = 2
      retry_count = 0
      
      begin
        # Stream the audio data
        @session.stream_audio(audio_buffer)
      rescue => stream_error
        error_message = stream_error.message
        logger.error "Error streaming audio to session: #{error_message}"
        
        # Retry logic for session not found errors
        if (error_message.include?("Session") && error_message.include?("not found or inactive")) && 
           retry_count < max_retry_attempts
          
          retry_count += 1
          logger.warn "Session not found or inactive, attempt #{retry_count}/#{max_retry_attempts} to recreate"
          
          # Reset session objects
          @session = nil
          @nova_sonic_client = nil
          
          # Wait with backoff before retrying
          sleep_time = [0.5 * (2 ** retry_count), 5].min
          logger.info "Waiting #{sleep_time}s before recreating session..."
          sleep(sleep_time)
          
          # Try to recreate the session
          setup_nova_sonic_session
          setup_audio_start
          
          # Retry streaming the same audio data
          retry
        elsif error_message.include?("ValidationException") || 
              error_message.include?("Invalid input") ||
              error_message.include?("Connection is closed due to errors")
          
          handle_session_validation_error(error_message)
        else
          # For other errors, attempt standard session restart
          logger.info "Attempting to restart the session after error"
          cleanup_nova_sonic_session
          transmit({ 
            type: 'error',
            message: 'Error streaming audio to AWS, session will be reset',
            details: error_message 
          })
        end
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
    
    # Capture more details about the error
    error_type = if error_message.include?("ValidationException")
      "validation_exception"
    elsif error_message.include?("Connection is closed")
      "connection_closed"
    elsif error_message.include?("Invalid input request")
      "invalid_input"
    else
      "unknown"
    end
    
    # Check if AWS credentials might be the issue
    aws_credentials = {
      access_key_id: ENV['AWS_ACCESS_KEY_ID'],
      secret_access_key: ENV['AWS_SECRET_ACCESS_KEY'],
      session_token: ENV['AWS_SESSION_TOKEN']
    }
    
    credential_message = if aws_credentials[:session_token].present?
      # If using session token, it might have expired
      begin
        require 'aws-sdk-core'
        sts = Aws::STS::Client.new(region: 'us-east-1', credentials: Aws::Credentials.new(
          aws_credentials[:access_key_id],
          aws_credentials[:secret_access_key],
          aws_credentials[:session_token]
        ))
        identity = sts.get_caller_identity
        # If we get here, credentials are still valid
        "AWS credentials are valid (Account: #{identity.account})"
      rescue => e
        # Credentials might have expired
        if e.message.include?("expired")
          "AWS credentials have expired: #{e.message}"
        else
          "AWS credential error: #{e.message}"
        end
      end
    else
      "Using permanent AWS credentials"
    end
    
    logger.info "AWS credential status: #{credential_message}"
    
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
    
    # Log detailed diagnostics
    logger.warn "Error Diagnostics:"
    logger.warn "  Type: #{error_type}"
    logger.warn "  Message: #{error_message}"
    logger.warn "  Credentials: #{credential_message}"
    
    # Send error notification to client with more helpful details
    transmit({ 
      type: 'error',
      message: 'Speech session needs to be restarted',
      details: "The connection with AWS Bedrock speech service was interrupted. #{error_type == 'invalid_input' ? 'There may be an issue with the audio format.' : ''} #{credential_message.include?('expired') ? 'Your AWS credentials may have expired.' : ''}",
      error_type: error_type,
      credential_status: credential_message.include?('valid') ? 'valid' : 'issue'
    })
  end
end 