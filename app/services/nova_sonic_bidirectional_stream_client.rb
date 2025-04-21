require 'aws-sdk-bedrockruntime'
require 'securerandom'
require 'json'
require 'base64'
require 'timeout'
require 'aws-eventstream'

class NovaSonicBidirectionalStreamClient
  class StreamSession
    attr_reader :session_id, :client
    attr_accessor :is_active, :is_processing_audio, :audio_buffer_queue

    def initialize(session_id, client)
      @session_id = session_id
      @client = client
      @is_active = true
      @is_processing_audio = false
      @audio_buffer_queue = []
      @max_queue_size = 200
      @response_handlers = {}
    end

    def on_event(event_type, &block)
      @response_handlers[event_type] = block
    end

    def handle_event(event_type, data)
      handler = @response_handlers[event_type]
      handler&.call(data)
    end

    def stream_audio(audio_data)
      client.stream_audio_chunk(session_id, audio_data)
    end

    def end_audio_content
      client.send_content_end(session_id)
    end

    def end_prompt
      client.send_prompt_end(session_id)
    end

    def close
      client.send_session_end(session_id)
    end
  end

  def initialize(region: 'us-east-1', credentials: {})
    @region = region
    @credentials = credentials
    @active_sessions = {}
    @session_last_activity = {}
    @session_cleanup_in_progress = Set.new
    @logger = Rails.logger

    @bedrock_runtime_client = Aws::BedrockRuntime::Client.new(
      region: region,
      credentials: Aws::Credentials.new(
        credentials[:access_key_id],
        credentials[:secret_access_key]
      )
    )
  end

  def create_stream_session(session_id = SecureRandom.uuid)
    if @active_sessions[session_id]
      raise "Stream session with ID #{session_id} already exists"
    end

    session = {
      queue: [],
      prompt_name: SecureRandom.uuid,
      audio_content_id: SecureRandom.uuid,
      is_active: true,
      is_prompt_start_sent: false,
      is_audio_content_start_sent: false,
      response_handlers: {}
    }

    stream_session = StreamSession.new(session_id, self)
    session[:stream_session] = stream_session
    @active_sessions[session_id] = session
    stream_session
  end

  def initiate_session(session_id)
    session = @active_sessions[session_id]
    raise "Stream session #{session_id} not found" unless session

    begin
      setup_session_start_event(session_id)
      start_bidirectional_stream(session_id)
    rescue => e
      handle_session_error(session_id, e)
    end
  end

  def stream_audio_chunk(session_id, audio_data)
    session = @active_sessions[session_id]
    raise "Invalid session #{session_id} for audio streaming" unless session && session[:is_active] && session[:audio_content_id]

    base64_data = Base64.strict_encode64(audio_data)
    add_event_to_session_queue(session_id, {
      audioInput: {
        promptName: session[:prompt_name],
        contentName: session[:audio_content_id],
        content: base64_data
      }
    })
  end

  def send_content_end(session_id)
    session = @active_sessions[session_id]
    return unless session && session[:is_audio_content_start_sent]

    add_event_to_session_queue(session_id, {
      contentEnd: {
        promptName: session[:prompt_name],
        contentName: session[:audio_content_id]
      }
    })
    sleep 0.5 # Wait to ensure it's processed
  end

  def send_prompt_end(session_id)
    session = @active_sessions[session_id]
    return unless session && session[:is_prompt_start_sent]

    add_event_to_session_queue(session_id, {
      promptEnd: {
        promptName: session[:prompt_name]
      }
    })
    sleep 0.3 # Wait to ensure it's processed
  end

  def send_session_end(session_id)
    session = @active_sessions[session_id]
    return unless session

    add_event_to_session_queue(session_id, {
      sessionEnd: {}
    })
    sleep 0.3 # Wait to ensure it's processed

    session[:is_active] = false
    @active_sessions.delete(session_id)
    @session_last_activity.delete(session_id)
  end

  def setup_start_audio_event(session_id)
    @logger.info "Setting up startAudioContent event for session #{session_id}..."
    session = @active_sessions[session_id]
    return unless session

    @logger.info "Using audio content ID: #{session[:audio_content_id]}"
    # Audio content start
    add_event_to_session_queue(session_id, {
      contentStart: {
        promptName: session[:prompt_name],
        contentName: session[:audio_content_id],
        type: "AUDIO",
        interactive: true,
        role: "USER",
        audioInputConfiguration: {
          mediaType: "audio/x-raw",
          sampleRate: 16000,
          channels: 1,
          format: "pcm",
          sampleSize: 16
        }
      }
    })
    session[:is_audio_content_start_sent] = true
    @logger.info "Initial events setup complete for session #{session_id}"
  end

  private

  def setup_session_start_event(session_id)
    session = @active_sessions[session_id]
    return unless session

    add_event_to_session_queue(session_id, {
      sessionStart: {
        inferenceConfiguration: {
          maxTokens: 1024,
          topP: 0.9,
          temperature: 0.7
        }
      }
    })
  end

  def start_bidirectional_stream(session_id)
    session = @active_sessions[session_id]
    return unless session

    begin
      @logger.info "Starting bidirectional stream for session #{session_id}..."
      
      # Set a timeout for the initial connection
      Timeout.timeout(30) do
        request_params = {
          model_id: 'amazon.nova-sonic-v1:0'
          # No other params needed here, input stream handled by block
        }
        @logger.debug "Sending request to AWS Bedrock with model_id: #{request_params[:model_id]}"

        # Call the method with a block to handle the input stream
        response = @bedrock_runtime_client.invoke_model_with_bidirectional_stream(request_params) do |input_stream|
          @logger.info "Input stream opened via block for session #{session_id}"

          # Process initial events from the queue immediately upon connection
          while !session[:queue].empty? && session[:is_active]
            event_data = session[:queue].shift
            @logger.debug "Writing initial event to input stream for session #{session_id}: #{event_data.inspect}"
            input_stream.signal_event(
              event_type: :chunk,
              payload: StringIO.new(event_data.to_json)
            )
          end

          # Start a thread to handle subsequent events
          Thread.new do
            begin
              while session[:is_active]
                if !session[:queue].empty?
                  event_data = session[:queue].shift
                  @logger.debug "Writing subsequent event to input stream for session #{session_id}: #{event_data.inspect}"
                  input_stream.signal_event(
                    event_type: :chunk,
                    payload: StringIO.new(event_data.to_json)
                  )
                else
                  sleep 0.1 # Prevent busy-waiting
                end
              end
              @logger.info "Session #{session_id} is no longer active, ending input stream signal."
              input_stream.signal_end_stream
            rescue => e
              @logger.error "Error in input event sending thread for session #{session_id}: #{e.message}\n#{e.backtrace.join("\n")}"
              begin
                input_stream.signal_end_stream unless input_stream.nil? || input_stream.closed?
              rescue => close_error
                @logger.error "Error trying to close input stream after thread error: #{close_error.message}"
              end
            end
          end
          # Block finishes here, but background thread continues sending
        end # End of block for invoke_model_with_bidirectional_stream

        @logger.info "invoke_model_with_bidirectional_stream called, processing response body for session #{session_id}"

        # Process the response stream (output events)
        response.body.each do |event|
          if event.respond_to?(:payload)
             payload_bytes = event.payload.read
             unless payload_bytes.empty?
                begin
                   json_response = JSON.parse(payload_bytes)
                   if json_response.is_a?(Hash) && json_response.key?('event')
                      event_type = json_response['event'].keys.first
                      event_data = json_response['event'][event_type]
                      @logger.debug "Received event for session #{session_id}: #{event_type}"
                      session[:stream_session]&.handle_event(event_type, event_data)
                   else
                     @logger.debug "Received non-event JSON structure for session #{session_id}: #{json_response.inspect}"
                   end
                rescue JSON::ParserError => e
                   @logger.error "Failed to parse JSON response chunk for session #{session_id}: #{e.message}"
                rescue => e
                   @logger.error "Error processing event payload for session #{session_id}: #{e.message}\n#{e.backtrace.join("\n")}"
                end
             end
          elsif event.is_a?(::EventStream::DecodedEvent)
             @logger.debug "Received decoded event of type: #{event.event_type} for session #{session_id}"
          else
             @logger.warn "Received event object of unexpected type: #{event.class.name} for session #{session_id}"
          end
        end
        @logger.info "Finished processing response body for session #{session_id}"

      end
    rescue Timeout::Error => e
      @logger.error "Connection timeout for session #{session_id}: #{e.message}"
      handle_session_error(session_id, e)
    rescue Aws::BedrockRuntime::Errors::ServiceError => e
      @logger.error "AWS Bedrock service error for session #{session_id}: #{e.message}"
      handle_session_error(session_id, e)
    rescue => e
      @logger.error "Unexpected error starting bidirectional stream for session #{session_id}: #{e.message}\n#{e.backtrace.join("\n")}"
      handle_session_error(session_id, e)
    end
  end

  def create_session_iterator(session_id)
    session = @active_sessions[session_id]
    return unless session

    {
      sessionId: session_id,
      promptName: session[:prompt_name],
      audioContentId: session[:audio_content_id]
    }
  end

  def add_event_to_session_queue(session_id, event_data)
    session = @active_sessions[session_id]
    return unless session && session[:is_active]

    update_session_activity(session_id)
    session[:queue] << event_data
  end

  def update_session_activity(session_id)
    @session_last_activity[session_id] = Time.now.to_i
  end

  def handle_session_error(session_id, error)
    session = @active_sessions[session_id]
    return unless session

    session[:stream_session]&.handle_event('error', {
      source: 'bidirectionalStream',
      error: error.message
    })

    if session[:is_active]
      send_session_end(session_id)
    end
  end
end 