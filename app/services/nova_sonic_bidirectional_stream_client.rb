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
      client.end_audio_content(session_id)
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

    @bedrock_runtime_client = Aws::BedrockRuntime::AsyncClient.new(
      region: region,
      credentials: Aws::Credentials.new(
        credentials[:access_key_id],
        credentials[:secret_access_key]
      ),
      enable_alpn: true
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
      setup_initial_events(session_id)
      start_bidirectional_stream(session_id)
    rescue => e
      handle_session_error(session_id, e)
    end
  end

  def stream_audio_chunk(session_id, audio_data)
    session = @active_sessions[session_id]
    # Add logging here to inspect the session state before the check
    if session
      @logger.debug "Checking session state in stream_audio_chunk for #{session_id}: is_active=#{session[:is_active]}, audio_content_id=#{session[:audio_content_id]}"
    else
      @logger.debug "Session #{session_id} not found in @active_sessions within stream_audio_chunk."
    end

    raise "Invalid session #{session_id} for audio streaming" unless session && session[:is_active] && session[:audio_content_id]

    base64_data = Base64.strict_encode64(audio_data)
    audio_event = {
      event: {
        audioInput: {
          promptName: session[:prompt_name],
          contentName: session[:audio_content_id],
          content: base64_data,
          role: "USER"
        }
      }
    }
    
    @logger.info "Streaming audio chunk for session #{session_id}"
    input_stream = session[:input_stream]
    if input_stream
      input_stream.signal_chunk_event(bytes: audio_event.to_json)
    else
      @logger.error "No input stream available for session #{session_id}"
    end
  end

  def send_content_end(session_id)
    session = @active_sessions[session_id]
    return unless session && session[:is_audio_content_start_sent]

    add_event_to_session_queue(session_id, {
      event: {
        contentEnd: {
          promptName: session[:prompt_name],
          contentName: session[:audio_content_id]
        }
      }
    })
    sleep 0.5 # Wait to ensure it's processed
  end

  def send_prompt_end(session_id)
    session = @active_sessions[session_id]
    return unless session && session[:is_prompt_start_sent]

    add_event_to_session_queue(session_id, {
      event: {
        promptEnd: {
          promptName: session[:prompt_name]
        }
      }
    })
    sleep 0.3 # Wait to ensure it's processed
  end

  def send_session_end(session_id)
    session = @active_sessions[session_id]
    return unless session

    add_event_to_session_queue(session_id, {
      event: {
        sessionEnd: {}
      }
    })
    sleep 0.3 # Wait to ensure it's processed

    session[:is_active] = false
    @active_sessions.delete(session_id)
    @session_last_activity.delete(session_id)
  end

  def end_audio_content(session_id)
    session = @active_sessions[session_id]
    return unless session && session[:is_audio_content_start_sent]

    content_end_event = {
      event: {
        contentEnd: {
          promptName: session[:prompt_name],
          contentName: session[:audio_content_id]
        }
      }
    }

    input_stream = session[:input_stream]
    if input_stream
      input_stream.signal_chunk_event(bytes: content_end_event.to_json)
      @logger.info "Sent contentEnd event for session #{session_id}"
    else
      @logger.error "No input stream available for session #{session_id}"
    end
  end

  def end_session(session_id)
    session = @active_sessions[session_id]
    return unless session

    session_end_event = {
      event: {
        sessionEnd: {}
      }
    }

    input_stream = session[:input_stream]
    if input_stream
      input_stream.signal_chunk_event(bytes: session_end_event.to_json)
      input_stream.signal_end_stream
      
      # Wait for the response to complete
      async_resp = session[:async_resp]
      async_resp.wait if async_resp
      
      finalize_session(session_id)
    else
      @logger.error "No input stream available for session #{session_id}, attempting finalize anyway."
      finalize_session(session_id)
    end
  end

  private

  def setup_initial_events(session_id)
    session = @active_sessions[session_id]
    return unless session

    # Define a temporary text content name
    text_content_name = SecureRandom.uuid

    # Clear the queue and add all required initial events
    session[:queue].clear
    session_start_event = {
      event: {
        sessionStart: {
          inferenceConfiguration: {
            maxTokens: 1024, # Example value, adjust as needed
            topP: 0.9,       # Example value, adjust as needed
            temperature: 0.7 # Example value, adjust as needed
          }
        }
      }
    }
    prompt_start_event = {
      "event": {
        "promptStart": {
          "promptName": session[:prompt_name],
          "textOutputConfiguration": { # Added based on example.rb
            "mediaType": "text/plain"
          },
          "audioOutputConfiguration": { # Added based on example.rb
            "mediaType": "audio/lpcm", # Using lpcm as in example
            "sampleRateHertz": 16000, # Match input sample rate
            "sampleSizeBits": 16,     # Match input sample size
            "channelCount": 1,        # Match input channels
            "voiceId": "en_us_matthew", # Example voice
            "encoding": "base64",
            "audioType": "SPEECH"
          }
          # Omitting tool configurations for now unless needed
        }
      }
    }
    # Add System Prompt Sequence (based on example.rb)
    text_content_start_event = {
      "event": {
        "contentStart": {
          "promptName": session[:prompt_name],
          "contentName": text_content_name, # Use the temp text content name
          "type": "TEXT",
          "interactive": true,
          "textInputConfiguration": {
            "mediaType": "text/plain"
          }
        }
      }
    }
    system_prompt_text_event = {
      "event": {
        "textInput": {
          "promptName": session[:prompt_name],
          "contentName": text_content_name, # Use the temp text content name
          # Use the same system prompt as example.rb
          "content": "You are a friend. The user and you will engage in a spoken dialog exchanging the transcripts of a natural real-time conversation. Keep your responses short, generally two or three sentences for chatty scenarios.",
          "role": "SYSTEM"
        }
      }
    }
    text_content_end_event = {
      "event": {
        "contentEnd": {
          "promptName": session[:prompt_name],
          "contentName": text_content_name # Use the temp text content name
        }
      }
    }
    # End System Prompt Sequence
    audio_content_start_event = {
      event: {
        contentStart: {
          promptName: session[:prompt_name],
          contentName: session[:audio_content_id],
          type: "AUDIO",
          interactive: true,
          role: "USER",
          audioInputConfiguration: { # Consistent with example.rb and existing code
            mediaType: "audio/lpcm", # Using lpcm as in example
            sampleRateHertz: 16000,  # Renamed from sampleRate
            sampleSizeBits: 16,    # Renamed from sampleSize
            channelCount: 1,       # Renamed from channels
            encoding: "base64",     # Added encoding
            audioType: "SPEECH"     # Added audioType
          }
        }
      }
    }

    add_event_to_session_queue(session_id, session_start_event)
    add_event_to_session_queue(session_id, prompt_start_event)
    # Enqueue system prompt sequence
    add_event_to_session_queue(session_id, text_content_start_event)
    add_event_to_session_queue(session_id, system_prompt_text_event)
    add_event_to_session_queue(session_id, text_content_end_event)
    # Enqueue audio start
    add_event_to_session_queue(session_id, audio_content_start_event)

    # Mark prompt as started since we just queued the event
    session[:is_prompt_start_sent] = true
    # Mark audio content as started since we just queued the event
    session[:is_audio_content_start_sent] = true # This was set in the old setup_start_audio_event

    @logger.info "Initial events sessionStart, promptStart, system prompt sequence, audio contentStart enqueued for session #{session_id}"
  end

  def start_bidirectional_stream(session_id)
    session = @active_sessions[session_id]
    return unless session

    begin
      @logger.info "Starting bidirectional stream for session #{session_id}..."
      @logger.info "Event queue before stream start: #{session[:queue].inspect}"
      if session[:queue].empty?
        @logger.warn "Event queue is empty before stream start! Bedrock expects initial events."
      else
        first_event = session[:queue].first
        @logger.info "First event JSON: #{first_event.is_a?(Hash) ? first_event.to_json : first_event}"
      end

      input_stream = Aws::BedrockRuntime::EventStreams::InvokeModelWithBidirectionalStreamInput.new
      output_stream = Aws::BedrockRuntime::EventStreams::InvokeModelWithBidirectionalStreamOutput.new

      # Store the input stream in the session for later use
      session[:input_stream] = input_stream

      # Configure output stream handlers
      puts "Setting up output stream handler..."
      output_stream.on_event do |e|
        # Log the raw event object to see its structure and type
        puts "Output stream got an event: #{e.inspect}"
        if e[:event_type] == :chunk
          begin
            # Parse the JSON response
            response = JSON.parse(e[:bytes])
            if response['event'] && response['event']['audioOutput']
              # Handle audio output
              audio_data = Base64.strict_decode64(response['event']['audioOutput']['content'])
              session[:stream_session]&.handle_event('audioOutput', audio_data)
            elsif response['event'] && response['event']['textOutput']
              # Handle text output
              text_data = response['event']['textOutput']['content']
              session[:stream_session]&.handle_event('textOutput', text_data)
            else
              # Log if chunk doesn't contain expected keys
              puts "Received chunk without expected audioOutput or textOutput: #{response.inspect}"
            end
          rescue JSON::ParserError => json_e
            puts "Failed to parse JSON chunk: #{json_e}"
          rescue ArgumentError => b64_e # Catch potential Base64 errors
            puts "Failed to decode Base64 audio data: #{b64_e}"
          rescue => other_e
            puts "Error processing chunk event: #{other_e}"
          end
        elsif e[:event_type] == :error
          # Specifically handle error events from the stream
          puts "Output stream received an error event: #{e.inspect}"
          # You might want to trigger your session error handling here
          handle_session_error(session_id, StandardError.new("Stream error: #{e.inspect}"))
        else
          # Log any other unexpected event types
          puts "Output stream received an unhandled event type: #{e[:event_type]} - #{e.inspect}"
        end
      end

      puts "Starting bidirectional stream request..."
      # Start the async request with both input and output stream handlers
      async_resp = @bedrock_runtime_client.invoke_model_with_bidirectional_stream(
        model_id: "amazon.nova-sonic-v1:0",
        input_event_stream_handler: input_stream,
        output_event_stream_handler: output_stream
      )

      puts "Sending initial events..."
      # Signal your input events
      session[:queue].each do |event|
        event_json = event.is_a?(Hash) ? event.to_json : event
        # Log the event JSON being sent for careful comparison
        @logger.debug "Sending initial event for session #{session_id}: #{event_json}"
        input_stream.signal_chunk_event(bytes: event_json)
      end
      session[:queue].clear

      # Store the async response in the session, but don't wait on it here
      session[:async_resp] = async_resp

      # Wait for the stream to complete to allow output handlers to process
      async_resp.wait

      puts "Bidirectional stream initiated and initial events sent for session #{session_id}. Waiting for output events..."

    rescue Timeout::Error => e
      # Simplify logging to just puts
      puts "!!! RESCUE BLOCK: Timeout::Error entered !!!"
      # @logger.error "Timeout occurred during stream initiation for session #{session_id}: #{e.message}"
      # puts "Connection timeout for session #{session_id}: #{e.message}" # Keep existing puts for console visibility
      handle_session_error(session_id, e)
    rescue Aws::BedrockRuntime::Errors::ServiceError => e
      # Simplify logging to just puts
      puts "!!! RESCUE BLOCK: Aws::BedrockRuntime::Errors::ServiceError entered !!!"
      # @logger.error "AWS Bedrock service error during stream initiation for session #{session_id}: #{e.message}\n#{e.backtrace.join("\n")}"
      # puts "AWS Bedrock service error for session #{session_id}: #{e.message}\n#{e.backtrace.join("\n")}" # Keep existing puts
      handle_session_error(session_id, e)
    rescue => e # Catch-all for any other error within the outer begin
      # Log ONLY the error class name before handling
      error_message = "Generic rescue block caught error of class: #{e.class.name}"
      @logger.error error_message
      puts error_message # Also try puts again, just in case
      handle_session_error(session_id, e)
    end # End of outer begin/rescue block
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
      end_session(session_id)
    end
  end

  def finalize_session(session_id)
    # Add logging at the very start of this method
    @logger.warn "!!! Finalizing session #{session_id} - Called from: #{caller.first}"
    puts "!!! Finalizing session #{session_id} - Called from: #{caller.first}" # Also puts for console visibility

    session = @active_sessions[session_id]
    return unless session # Already finalized or never existed

    @logger.info "Finalizing session #{session_id}..."
    session[:is_active] = false
    # Clean up resources, maybe close streams if not already done by SDK
    # input_stream = session[:input_stream]
    # input_stream.close if input_stream # Check SDK docs if explicit close is needed

    @active_sessions.delete(session_id)
    @session_last_activity.delete(session_id)
    @logger.info "Session #{session_id} finalized and removed."
  end
end 