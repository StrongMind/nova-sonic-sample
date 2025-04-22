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
      setup_nova_sonic_session
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
      transmit({ type: 'error', message: 'System prompt not yet implemented' })
    when 'audio_start'
      logger.info "Processing audio_start for session #{@session_id}"
      if @session.nil?
        logger.error "No active session for audio_start"
        transmit({ type: 'error', message: 'No active session' })
        return
      end
      transmit({ type: 'audio_started', message: 'Audio streaming initialized' })
    when 'audio_input'
      if message_data['audio_data'].present?
        logger.info "Processing audio_input for session #{@session_id}"
        if @session.nil?
          logger.error "No active session for audio_input"
          transmit({ type: 'error', message: 'No active session' })
          return
        end
        # Strip the data URL prefix if present
        audio_data = message_data['audio_data']
        if audio_data.start_with?('data:')
          logger.debug "Stripping data URL prefix from audio data"
          audio_data = audio_data.split(',', 2).last
        end
        stream_audio(audio_data)
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
  end

  private

  def setup_nova_sonic_session
    @nova_sonic_client = NovaSonicBidirectionalStreamClient.new(
      region: 'us-east-1',
      credentials: {
        access_key_id: ENV['AWS_ACCESS_KEY_ID'],
        secret_access_key: ENV['AWS_SECRET_ACCESS_KEY']
      }
    )
    
    @session = @nova_sonic_client.create_stream_session(@session_id)
    setup_event_handlers
    @nova_sonic_client.initiate_session(@session_id)
  end

  def setup_event_handlers
    @session.on_event('textOutput') do |data|
      transmit({ type: 'textOutput', data: data })
    end

    @session.on_event('audioOutput') do |data|
      transmit({ type: 'audioOutput', data: data })
    end

    @session.on_event('error') do |data|
      transmit({ type: 'error', data: data })
    end

    @session.on_event('toolUse') do |data|
      transmit({ type: 'toolUse', data: data })
    end

    @session.on_event('toolResult') do |data|
      transmit({ type: 'toolResult', data: data })
    end

    @session.on_event('contentEnd') do |data|
      transmit({ type: 'contentEnd', data: data })
    end
  end

  def stream_audio(audio_data)
    return unless @session
    
    begin
      logger.info "Processing audio data for session #{@session_id}"
      
      # Convert base64 string to binary data
      audio_buffer = Base64.decode64(audio_data)
      
      if audio_buffer.empty?
        logger.error "Decoded audio buffer is empty for session #{@session_id}"
        transmit({ 
          type: 'error',
          message: 'Empty audio buffer after decoding'
        })
        return
      end
      
      logger.debug "Streaming #{audio_buffer.size} bytes of audio data for session #{@session_id}"
      @session.stream_audio(audio_buffer)
      
    rescue ArgumentError => e
      logger.error "Invalid base64 audio data for session #{@session_id}: #{e.message}"
      transmit({ 
        type: 'error',
        message: 'Invalid audio data format',
        details: e.message 
      })
    rescue => e
      logger.error "Error processing audio for session #{@session_id}: #{e.message}"
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
      # Remove the call that signals the end of the entire input stream
      # @nova_sonic_client.signal_input_stream_end(@session_id)
      logger.info "Requested cleanup for session #{@session_id}: Sent contentEnd for last audio block."
    rescue => e
      logger.error "Error during session cleanup request for #{@session_id}: #{e.message}"
    ensure
      # Only nullify references here; actual client-side session object removal
      # happens in the client's finalize_session method when an error occurs
      # or potentially via a specific "close" request from the client.
      @session = nil
      @nova_sonic_client = nil
    end
  end
end 