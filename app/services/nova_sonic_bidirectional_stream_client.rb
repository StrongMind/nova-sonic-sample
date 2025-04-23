require 'aws-sdk-bedrockruntime'
require 'securerandom'
require 'json'
require 'base64'
require 'timeout'
require 'logger'
require 'aws-eventstream'
require 'concurrent'

class NovaSonicBidirectionalStreamClient
  # Default configurations
  DEFAULT_TEXT_CONFIGURATION = {
    mediaType: 'text/plain'
  }
  
  DEFAULT_AUDIO_INPUT_CONFIGURATION = {
    mediaType: 'audio/lpcm',
    sampleRateHertz: 16000,
    sampleSizeBits: 16,
    channelCount: 1,
    audioType: 'SPEECH',
    encoding: 'base64'
  }
  
  DEFAULT_AUDIO_OUTPUT_CONFIGURATION = {
    mediaType: 'audio/lpcm',
    sampleRateHertz: 24000,
    sampleSizeBits: 16,
    channelCount: 1,
    voiceId: 'en_us_tiffany',
    encoding: 'base64',
    audioType: 'SPEECH'
  }
  
  DEFAULT_SYSTEM_PROMPT = "You are a friend. The user and you will engage in a spoken dialog exchanging the transcripts of a natural real-time conversation. Keep your responses short, generally two or three sentences for chatty scenarios."
  
  DEFAULT_TOOL_SCHEMA = {
    type: 'object',
    properties: {}
  }
  
  WEATHER_TOOL_SCHEMA = {
    type: 'object',
    properties: {
      latitude: {
        type: 'number',
        description: 'The latitude coordinate of the location.'
      },
      longitude: {
        type: 'number',
        description: 'The longitude coordinate of the location.'
      }
    },
    required: ['latitude', 'longitude']
  }

  class StreamSession
    attr_reader :session_id, :client
    
    def initialize(session_id, client)
      @session_id = session_id
      @client = client
      @is_active = true
      @handlers = {}
      @logger = Rails.logger rescue Logger.new(STDOUT)
    end
    
    # Register event handlers for this specific session
    def on_event(event_type, &handler)
      @handlers[event_type] = handler
      self # For chaining
    end
    
    def handle_event(event_type, data)
      puts "StreamSession(#{session_id}): Handling event #{event_type}"
      
      if @handlers[event_type]
        puts "StreamSession(#{session_id}): Found handler for #{event_type}"
        begin
          @handlers[event_type].call(data)
          puts "StreamSession(#{session_id}): Successfully executed handler for #{event_type}"
        rescue => e
          puts "StreamSession(#{session_id}): Error in #{event_type} handler: #{e.message}"
          puts e.backtrace.join("\n")
          @logger.error "Error in #{event_type} handler for session #{session_id}: #{e.message}"
        end
      else
        puts "StreamSession(#{session_id}): No handler registered for event type #{event_type}"
      end
      
      # Also dispatch to "any" handlers
      if @handlers['any']
        puts "StreamSession(#{session_id}): Dispatching to 'any' handler"
        begin
          @handlers['any'].call({ type: event_type, data: data })
          puts "StreamSession(#{session_id}): Successfully executed 'any' handler"
        rescue => e
          puts "StreamSession(#{session_id}): Error in 'any' handler: #{e.message}"
          puts e.backtrace.join("\n")
          @logger.error "Error in 'any' handler for session #{session_id}: #{e.message}"
        end
      end
    end
    
    # Stream audio for this session - simplified to match example.rb
    def stream_audio(audio_data)
      return unless @is_active
      client.stream_audio_chunk(session_id, audio_data)
    end
    
    # Send content end
    def end_audio_content
      return unless @is_active
      client.send_content_end(session_id)
    end
    
    # End prompt
    def end_prompt
      return unless @is_active
      client.send_prompt_end(session_id)
    end
    
    # Close the session
    def close
      return unless @is_active
      @is_active = false
      client.send_session_end(session_id)
      @logger.info "Session #{session_id} close completed"
    end
  end
  
  attr_reader :active_sessions
  
  def initialize(region: 'us-east-1', credentials: {}, inference_config: nil)
    @region = region
    @credentials = credentials
    @active_sessions = {}
    @session_last_activity = {}
    @session_cleanup_in_progress = Set.new
    @logger = Rails.logger rescue Logger.new(STDOUT)
    
    @inference_config = inference_config || {
      maxTokens: 10000,
      topP: 0.95,
      temperature: 0.9
    }
    
    # Initialize AWS client with HTTP2 configuration
    puts "Initializing AWS Bedrock runtime client with HTTP2 support..."
    
    # Initialize AWS client with proper configuration
    # Only use supported parameters
    client_options = {
      region: region,
      http_wire_trace: false, # Enable HTTP tracing for debugging
      enable_alpn: true     # Enable ALPN for HTTP/2
    }
    
    # Add credentials if provided
    if credentials && !credentials.empty?
      # Use session token if provided
      if credentials[:session_token]
        puts "Using AWS credentials with session token"
        client_options[:credentials] = Aws::Credentials.new(
          credentials[:access_key_id],
          credentials[:secret_access_key],
          credentials[:session_token]
        )
      else
        puts "Using AWS credentials without session token"
        client_options[:credentials] = Aws::Credentials.new(
          credentials[:access_key_id],
          credentials[:secret_access_key]
        )
      end
    else
      puts "No explicit credentials provided, using default AWS credential provider chain"
    end
    
    @bedrock_runtime_client = Aws::BedrockRuntime::AsyncClient.new(client_options)
    
    puts "AWS Bedrock runtime client initialized."
  end
  
  # Create a new streaming session
  def create_stream_session(session_id = SecureRandom.uuid)
    if @active_sessions[session_id]
      raise "Stream session with ID #{session_id} already exists"
    end
    
    session_data = {
      queue: [],
      queue_mutex: Mutex.new,
      queue_signal: Concurrent::Event.new,
      close_signal: Concurrent::Event.new,
      tool_use_content: nil,
      tool_use_id: "",
      tool_name: "",
      prompt_name: SecureRandom.uuid,
      inference_config: @inference_config,
      is_active: true,
      is_prompt_start_sent: false,
      is_audio_content_start_sent: false,
      audio_content_id: SecureRandom.uuid
    }
    
    # Create stream session and add to session data
    stream_session = StreamSession.new(session_id, self)
    session_data[:stream_session] = stream_session
    
    @active_sessions[session_id] = session_data
    @session_last_activity[session_id] = Time.now.to_i
    
    stream_session
  end
  
  def is_session_active(session_id)
    session_data = @active_sessions[session_id]
    !session_data.nil? && session_data[:is_active]
  end
  
  def get_active_sessions
    @active_sessions.keys
  end
  
  def get_last_activity_time(session_id)
    @session_last_activity[session_id] || 0
  end
  
  def update_session_activity(session_id)
    @session_last_activity[session_id] = Time.now.to_i
  end
  
  def is_cleanup_in_progress(session_id)
    @session_cleanup_in_progress.include?(session_id)
  end
  
  # Initiate a bidirectional stream session - simplified to match example.rb
  def initiate_session(session_id)
    session_data = @active_sessions[session_id]
    if !session_data
      raise "Stream session #{session_id} not found"
    end
    
    # Skip if this session is already being initialized
    if session_data[:initializing]
      return
    end
    
    # Mark session as being initialized
    session_data[:initializing] = true
    
    begin
      # Very simple approach - directly based on example.rb
      input_stream = Aws::BedrockRuntime::EventStreams::InvokeModelWithBidirectionalStreamInput.new
      output_stream = Aws::BedrockRuntime::EventStreams::InvokeModelWithBidirectionalStreamOutput.new
      
      # Configure output stream handlers
      output_stream.on_event do |event|
        puts "Received event: #{event.class} - #{event.inspect}"
        
        # If it's a Hash, handle as before
        if event.is_a?(Hash)
          puts "Event is a Hash"
          
          if event.key?(:event_type)
            puts "Event has :event_type key: #{event[:event_type]}"
            
            if event[:event_type] == :chunk && event[:bytes]
              begin
                response_data = JSON.parse(event[:bytes])
                
                if response_data['event']
                  event_type = response_data['event'].keys.first
                  event_data = response_data['event'][event_type]
                  
                  # Dispatch based on event type
                  dispatch_event_for_session(session_id, event_type, event_data)
                end
              rescue JSON::ParserError => e
                @logger.error "Failed to parse JSON response: #{e.message}"
              end
            elsif event[:event_type] == :error
              @logger.error "Stream error for session #{session_id}: #{event[:error]}"
              dispatch_event_for_session(session_id, 'error', {
                source: 'stream',
                error: event[:error]
              })
            end
          else
            puts "Event is a Hash but doesn't have :event_type key. Keys: #{event.keys.inspect}"
          end
        # If it's a BidirectionalOutputPayloadPart type, handle it
        elsif defined?(Aws::BedrockRuntime::Types::BidirectionalOutputPayloadPart) && 
              event.is_a?(Aws::BedrockRuntime::Types::BidirectionalOutputPayloadPart)
          puts "Event is a BidirectionalOutputPayloadPart"
          if event.event_type == :chunk && event.bytes
            begin
              response_data = JSON.parse(event.bytes)
              
              if response_data['event']
                event_type = response_data['event'].keys.first
                event_data = response_data['event'][event_type]
                
                # Dispatch based on event type
                dispatch_event_for_session(session_id, event_type, event_data)
              end
            rescue JSON::ParserError => e
              @logger.error "Failed to parse JSON response: #{e.message}"
            end
          elsif event.event_type == :error
            @logger.error "Stream error for session #{session_id}: #{event.error}"
            dispatch_event_for_session(session_id, 'error', {
              source: 'stream',
              error: event.error
            })
          end
        # If it's an AWS SDK event class, handle appropriately
        elsif defined?(Aws::BedrockRuntime::Types) && event.is_a?(Aws::BedrockRuntime::Types.const_get("ChunkEvent"))
          puts "Event is a ChunkEvent"
          if event.bytes
            begin
              response_data = JSON.parse(event.bytes)
              
              if response_data['event']
                event_type = response_data['event'].keys.first
                event_data = response_data['event'][event_type]
                
                # Dispatch based on event type
                dispatch_event_for_session(session_id, event_type, event_data)
              end
            rescue JSON::ParserError => e
              @logger.error "Failed to parse JSON response: #{e.message}"
            end
          end
        # If it's a struct with a message property (likely an error)
        elsif event.is_a?(Struct) && event.respond_to?(:message)
          error_message = event.message
          @logger.error "Error in stream for session #{session_id}: #{error_message}"
          
          # Mark session for cleanup
          session_data[:is_active] = false
          
          # Dispatch detailed error event
          dispatch_event_for_session(session_id, 'error', {
            source: 'aws_bedrock',
            error: error_message,
            details: "AWS Bedrock returned an error. This could be due to expired credentials, invalid audio format, or service issues."
          })
        # Handle all other cases
        else
          puts "Unknown event type: #{event.class}"
          
          # Try to infer event type if it responds to event_type
          if event.respond_to?(:event_type)
            puts "Event responds to event_type: #{event.event_type}"
            event_type = event.event_type
            
            # Handle chunk events
            if event_type == :chunk && event.respond_to?(:bytes)
              begin
                response_data = JSON.parse(event.bytes)
                
                if response_data['event']
                  event_type = response_data['event'].keys.first
                  event_data = response_data['event'][event_type]
                  
                  # Dispatch based on event type
                  dispatch_event_for_session(session_id, event_type, event_data)
                end
              rescue JSON::ParserError => e
                @logger.error "Failed to parse JSON response: #{e.message}"
              end
            # Handle error events
            elsif event_type == :error && event.respond_to?(:error)
              @logger.error "Stream error for session #{session_id}: #{event.error}"
              dispatch_event_for_session(session_id, 'error', {
                source: 'stream',
                error: event.error
              })
            elsif event_type == :model_stream_error_exception
              message = event.respond_to?(:message) ? event.message : "Unknown model stream error"
              @logger.error "Model stream error for session #{session_id}: #{message}"
              
              # Mark session for cleanup
              session_data[:is_active] = false
              
              # Dispatch detailed error event
              dispatch_event_for_session(session_id, 'error', {
                source: 'model_stream',
                error: message,
                details: "AWS Bedrock returned a model stream error."
              })
            end
          else
            puts "Event doesn't respond to event_type. Attempting to introspect..."
            if event.respond_to?(:methods)
              puts "Available methods: #{event.methods - Object.methods}"
            end
          end
        end
      end
      
      # Generate UUIDs for the session
      prompt_id = SecureRandom.uuid
      text_content_id = SecureRandom.uuid
      audio_content_id = SecureRandom.uuid
      
      # Store the IDs in the session data
      session_data[:prompt_name] = prompt_id
      session_data[:audio_content_id] = audio_content_id
      
      # Start the request
      async_resp = @bedrock_runtime_client.invoke_model_with_bidirectional_stream(
        model_id: "amazon.nova-sonic-v1:0",
        input_event_stream_handler: input_stream,
        output_event_stream_handler: output_stream
      )
      
      # Create all the events exactly as in example.rb
      events = [
        # Start session
        {
          "event": {
            "sessionStart": {
              "inferenceConfiguration": {
                "maxTokens": 10000,
                "topP": 0.95,
                "temperature": 0.9
              }
            }
          }
        }.to_json,
        
        # Start prompt
        {
          "event": {
            "promptStart": {
              "promptName": prompt_id,
              "textOutputConfiguration": {
                "mediaType": "text/plain"
              },
              "audioOutputConfiguration": {
                "mediaType": "audio/lpcm",
                "sampleRateHertz": 16000,
                "sampleSizeBits": 16,
                "channelCount": 1,
                "voiceId": "en_us_tiffany",
                "encoding": "base64",
                "audioType": "SPEECH"
              },
              "toolUseOutputConfiguration": {
                "mediaType": "application/json"
              },
              "toolConfiguration": {
                "tools": []
              }
            }
          }
        }.to_json,
        
        # Start content
        {
          "event": {
            "contentStart": {
              "promptName": prompt_id,
              "contentName": text_content_id,
              "type": "TEXT",
              "interactive": true,
              "textInputConfiguration": {
                "mediaType": "text/plain"
              }
            }
          }
        }.to_json,
        
        # System Setup
        {
          "event": {
            "textInput": {
              "promptName": prompt_id,
              "contentName": text_content_id,
              "content": "You are a friend. The user and you will engage in a spoken dialog exchanging the transcripts of a natural real-time conversation. Keep your responses short, generally two or three sentences for chatty scenarios.",
              "role": "SYSTEM"
            }
          }
        }.to_json,
        
        # End System Setup
        {
          "event": {
            "contentEnd": {
              "promptName": prompt_id,
              "contentName": text_content_id
            }
          }
        }.to_json,
        
        # Start Audio Stream
        {
          "event": {
            "contentStart": {
              "promptName": prompt_id,
              "contentName": audio_content_id,
              "type": "AUDIO",
              "interactive": true,
              "audioInputConfiguration": {
                "mediaType": "audio/lpcm",
                "sampleRateHertz": 16000,
                "sampleSizeBits": 16,
                "channelCount": 1,
                "audioType": "SPEECH",
                "encoding": "base64"
              }
            }
          }
        }.to_json
      ]
      
      # Save the input_stream and async_resp to the session data
      session_data[:input_stream] = input_stream
      session_data[:async_resp] = async_resp
      
      # Send all initial events
      events.each do |event|
        begin
          input_stream.signal_chunk_event(bytes: event)
        rescue => e
          @logger.error "Error sending initial event: #{e.message}"
          raise "Failed to send initial event: #{e.message}"
        end
      end
      
      # Mark as active
      session_data[:is_active] = true
      session_data[:is_prompt_start_sent] = true
      session_data[:is_audio_content_start_sent] = true
    rescue => e
      @logger.error "Error initializing session #{session_id}: #{e.message}"
      
      dispatch_event_for_session(session_id, 'error', {
        source: 'initialization',
        error: e.message
      })
      
      if session_data[:is_active]
        session_data[:is_active] = false
      end
    ensure
      session_data[:initializing] = false
    end
  end
  
  # Start the bidirectional stream with AWS Bedrock
  def start_bidirectional_stream(session_id, initial_events = [])
    session_data = @active_sessions[session_id]
    return unless session_data
    
    begin
      @logger.info "Starting bidirectional stream for session #{session_id}..."
      
      input_stream = Aws::BedrockRuntime::EventStreams::InvokeModelWithBidirectionalStreamInput.new
      output_stream = Aws::BedrockRuntime::EventStreams::InvokeModelWithBidirectionalStreamOutput.new
      
      # Store the input stream in the session for later use
      session_data[:input_stream] = input_stream
      
      # Configure output stream handlers
      output_stream.on_event do |event|
        puts "Received event: #{event.class} - #{event.inspect}"
        
        # If it's a Hash, handle as before
        if event.is_a?(Hash)
          puts "Event is a Hash"
          
          if event.key?(:event_type)
            puts "Event has :event_type key: #{event[:event_type]}"
            
            if event[:event_type] == :chunk && event[:bytes]
              begin
                response_data = JSON.parse(event[:bytes])
                
                if response_data['event']
                  event_type = response_data['event'].keys.first
                  event_data = response_data['event'][event_type]
                  
                  # Dispatch based on event type
                  dispatch_event_for_session(session_id, event_type, event_data)
                end
              rescue JSON::ParserError => e
                @logger.error "Failed to parse JSON response: #{e.message}"
              end
            elsif event[:event_type] == :error
              @logger.error "Stream error for session #{session_id}: #{event[:error]}"
              dispatch_event_for_session(session_id, 'error', {
                source: 'stream',
                error: event[:error]
              })
            end
          else
            puts "Event is a Hash but doesn't have :event_type key. Keys: #{event.keys.inspect}"
          end
        # If it's a BidirectionalOutputPayloadPart type, handle it
        elsif defined?(Aws::BedrockRuntime::Types::BidirectionalOutputPayloadPart) && 
              event.is_a?(Aws::BedrockRuntime::Types::BidirectionalOutputPayloadPart)
          puts "Event is a BidirectionalOutputPayloadPart"
          if event.event_type == :chunk && event.bytes
            begin
              response_data = JSON.parse(event.bytes)
              
              if response_data['event']
                event_type = response_data['event'].keys.first
                event_data = response_data['event'][event_type]
                
                # Dispatch based on event type
                dispatch_event_for_session(session_id, event_type, event_data)
              end
            rescue JSON::ParserError => e
              @logger.error "Failed to parse JSON response: #{e.message}"
            end
          elsif event.event_type == :error
            @logger.error "Stream error for session #{session_id}: #{event.error}"
            dispatch_event_for_session(session_id, 'error', {
              source: 'stream',
              error: event.error
            })
          end
        # If it's an AWS SDK event class, handle appropriately
        elsif defined?(Aws::BedrockRuntime::Types) && event.is_a?(Aws::BedrockRuntime::Types.const_get("ChunkEvent"))
          puts "Event is a ChunkEvent"
          if event.bytes
            begin
              response_data = JSON.parse(event.bytes)
              
              if response_data['event']
                event_type = response_data['event'].keys.first
                event_data = response_data['event'][event_type]
                
                # Dispatch based on event type
                dispatch_event_for_session(session_id, event_type, event_data)
              end
            rescue JSON::ParserError => e
              @logger.error "Failed to parse JSON response: #{e.message}"
            end
          end
        # If it's a struct with a message property (likely an error)
        elsif event.is_a?(Struct) && event.respond_to?(:message)
          error_message = event.message
          @logger.error "Error in stream for session #{session_id}: #{error_message}"
          
          # Mark session for cleanup
          session_data[:is_active] = false
          
          # Dispatch detailed error event
          dispatch_event_for_session(session_id, 'error', {
            source: 'aws_bedrock',
            error: error_message,
            details: "AWS Bedrock returned an error. This could be due to expired credentials, invalid audio format, or service issues."
          })
        # Handle all other cases
        else
          puts "Unknown event type: #{event.class}"
          
          # Try to infer event type if it responds to event_type
          if event.respond_to?(:event_type)
            puts "Event responds to event_type: #{event.event_type}"
            event_type = event.event_type
            
            # Handle chunk events
            if event_type == :chunk && event.respond_to?(:bytes)
              begin
                response_data = JSON.parse(event.bytes)
                
                if response_data['event']
                  event_type = response_data['event'].keys.first
                  event_data = response_data['event'][event_type]
                  
                  # Dispatch based on event type
                  dispatch_event_for_session(session_id, event_type, event_data)
                end
              rescue JSON::ParserError => e
                @logger.error "Failed to parse JSON response: #{e.message}"
              end
            # Handle error events
            elsif event_type == :error && event.respond_to?(:error)
              @logger.error "Stream error for session #{session_id}: #{event.error}"
              dispatch_event_for_session(session_id, 'error', {
                source: 'stream',
                error: event.error
              })
            elsif event_type == :model_stream_error_exception
              message = event.respond_to?(:message) ? event.message : "Unknown model stream error"
              @logger.error "Model stream error for session #{session_id}: #{message}"
              
              # Mark session for cleanup
              session_data[:is_active] = false
              
              # Dispatch detailed error event
              dispatch_event_for_session(session_id, 'error', {
                source: 'model_stream',
                error: message,
                details: "AWS Bedrock returned a model stream error."
              })
            elsif event_type == :initial_response
              puts "Received initial_response event: #{event.inspect}"
            elsif event_type == :complete
              puts "Received complete event: #{event.inspect}"
            else
              puts "Unhandled event type: #{event_type}, data: #{event.inspect}"
            end
          else
            puts "Event doesn't respond to event_type. Attempting to introspect..."
            if event.respond_to?(:methods)
              puts "Available methods: #{event.methods - Object.methods}"
            end
          end
        end
      end
      
      # Start the async request
      puts "Invoking Bedrock with bidirectional stream..."
      
      # Log request details
      puts "  Model ID: amazon.nova-sonic-v1:0"
      puts "  Session ID: #{session_id}"
      puts "  Initial events: #{initial_events.size}"
      
      async_resp = @bedrock_runtime_client.invoke_model_with_bidirectional_stream(
        model_id: "amazon.nova-sonic-v1:0",
        input_event_stream_handler: input_stream,
        output_event_stream_handler: output_stream
      )
      puts "Bedrock invocation initiated successfully"
      
      # Store the async response in the session
      session_data[:async_resp] = async_resp
      
      # Send initial events first in sequence
      if initial_events.any?
        begin
          initial_events.each_with_index do |event, index|
            puts "Sending initial event #{index+1}/#{initial_events.size} to Bedrock"
            input_stream.signal_chunk_event(bytes: event)
            puts "Successfully sent initial event #{index+1}"
          end
        rescue => e
          puts "Error sending initial events: #{e.message}"
          puts e.backtrace.join("\n") 
          raise
        end
      end
      
      # Now start the thread for additional events
      queue_thread = Thread.new do
        begin
          send_queued_events(session_id, input_stream)
        rescue => e
          puts "Error in queue thread: #{e.message}"
          puts e.backtrace.join("\n")
        end
      end
      
      # Wait for the stream to complete in a separate thread
      wait_thread = Thread.new do
        begin
          puts "Waiting for response stream to complete..."
          
          # Instead of wait_until, just use wait directly
          begin
            # Wait for async response to complete
            async_resp.wait
            puts "Response stream completed normally"
          rescue => e
            puts "Error during async_resp.wait: #{e.message}"
            puts e.backtrace.join("\n")
            
            # Dispatch error event
            dispatch_event_for_session(session_id, 'error', {
              source: 'stream_wait',
              error: e.message
            })
          end
        rescue => e
          puts "Error in wait thread: #{e.message}"
          puts e.backtrace.join("\n")
        end
      end
      
      # Don't block the current thread
      @logger.info "Bidirectional stream initiated for session #{session_id}"
      
    rescue => e
      @logger.error "Error starting bidirectional stream for session #{session_id}: #{e.message}"
      puts "Error starting bidirectional stream for session #{session_id}: #{e.message}"
      puts e.backtrace.join("\n")
      dispatch_event_for_session(session_id, 'error', {
        source: 'stream_start',
        error: e.message
      })
    end
  end
  
  # Send queued events to the input stream
  def send_queued_events(session_id, input_stream)
    session_data = @active_sessions[session_id]
    return unless session_data
    
    begin
      # First send all initially queued events
      session_data[:queue_mutex].synchronize do
        session_data[:queue].each_with_index do |event, index|
          begin
            input_stream.signal_chunk_event(bytes: event)
          rescue => e
            @logger.error "Error sending event #{index+1}: #{e.message}"
            raise # Re-raise to exit the loop
          end
        end
        session_data[:queue].clear
      end
      
      # Then wait for new events or close signal
      loop do        
        if !session_data[:is_active]
          break
        end
        
        event_triggered = session_data[:queue_signal].wait(0.1)
        
        # Check if we should close
        if !session_data[:is_active] || session_data[:close_signal].set?
          break
        end
        
        # Process any new events in the queue
        if event_triggered
          session_data[:queue_mutex].synchronize do
            queue_size = session_data[:queue].size
            return if queue_size == 0
            
            while session_data[:is_active] && !session_data[:queue].empty?
              event = session_data[:queue].shift
              event_json = event.to_json
              
              begin
                input_stream.signal_chunk_event(bytes: event_json)
              rescue => e
                @logger.error "Error sending queued event: #{e.message}"
              end
            end
          end
        end
      end
    rescue => e
      @logger.error "Critical error in send_queued_events for session #{session_id}: #{e.message}"
    end
  end
  
  # Process response from AWS Bedrock
  def process_response(session_id, response)
    session_data = @active_sessions[session_id]
    return unless session_data && session_data[:is_active]
    
    update_session_activity(session_id)
    
    begin
      if response['event']
        if response['event']['contentStart']
          dispatch_event_for_session(session_id, 'contentStart', response['event']['contentStart'])
        elsif response['event']['textOutput']
          dispatch_event_for_session(session_id, 'textOutput', response['event']['textOutput'])
        elsif response['event']['audioOutput']
          dispatch_event_for_session(session_id, 'audioOutput', response['event']['audioOutput'])
        elsif response['event']['toolUse']
          dispatch_event_for_session(session_id, 'toolUse', response['event']['toolUse'])
          
          # Store tool use information for later
          session_data[:tool_use_content] = response['event']['toolUse']
          session_data[:tool_use_id] = response['event']['toolUse']['toolUseId']
          session_data[:tool_name] = response['event']['toolUse']['toolName']
        elsif response['event']['contentEnd'] && response['event']['contentEnd']['type'] == 'TOOL'
          # Process tool use
          dispatch_event_for_session(session_id, 'toolEnd', {
            tool_use_content: session_data[:tool_use_content],
            tool_use_id: session_data[:tool_use_id],
            tool_name: session_data[:tool_name]
          })
          
          # Process tool call
          begin
            tool_result = process_tool_use(session_data[:tool_name], session_data[:tool_use_content])
            
            # Send tool result
            send_tool_result(session_id, session_data[:tool_use_id], tool_result)
            
            # Dispatch event about tool result
            dispatch_event_for_session(session_id, 'toolResult', {
              tool_use_id: session_data[:tool_use_id],
              result: tool_result
            })
          rescue => e
            @logger.error "Error processing tool use: #{e.message}"
            dispatch_event_for_session(session_id, 'error', {
              source: 'tool_use',
              error: e.message
            })
          end
        elsif response['event']['contentEnd']
          dispatch_event_for_session(session_id, 'contentEnd', response['event']['contentEnd'])
        else
          # Handle other events
          event_keys = response['event'].keys
          if !event_keys.empty?
            dispatch_event_for_session(session_id, event_keys.first, response['event'])
          else
            dispatch_event_for_session(session_id, 'unknown', response)
          end
        end
      end
    rescue => e
      @logger.error "Error processing response for session #{session_id}: #{e.message}"
    end
  end
  
  # Process tool use
  def process_tool_use(tool_name, tool_use_content)
    tool = tool_name.downcase
    
    case tool
    when "getdateandtimetool"
      time_zone = "America/Los_Angeles"
      current_time = Time.now.getlocal(Etc.find_timezone(time_zone).current_period.offset.to_s)
      
      {
        date: current_time.strftime("%Y-%m-%d"),
        year: current_time.year,
        month: current_time.month,
        day: current_time.day,
        dayOfWeek: current_time.strftime("%A").upcase,
        timezone: "PST",
        formattedTime: current_time.strftime("%I:%M %p")
      }
    when "getweathertool"
      @logger.info "weather tool"
      parsed_content = parse_tool_use_content_for_weather(tool_use_content)
      if !parsed_content
        raise "Failed to parse weather tool content"
      end
      fetch_weather_data(parsed_content[:latitude], parsed_content[:longitude])
    else
      @logger.info "Tool #{tool} not supported"
      raise "Tool #{tool} not supported"
    end
  end
  
  # Parse tool use content for weather
  def parse_tool_use_content_for_weather(tool_use_content)
    begin
      if tool_use_content && tool_use_content['content'].is_a?(String)
        parsed_content = JSON.parse(tool_use_content['content'])
        return {
          latitude: parsed_content['latitude'],
          longitude: parsed_content['longitude']
        }
      end
      nil
    rescue => e
      @logger.error "Failed to parse tool use content: #{e.message}"
      nil
    end
  end
  
  # Fetch weather data
  def fetch_weather_data(latitude, longitude)
    require 'net/http'
    require 'uri'
    
    url = URI.parse("https://api.open-meteo.com/v1/forecast?latitude=#{latitude}&longitude=#{longitude}&current_weather=true")
    
    begin
      response = Net::HTTP.get_response(url)
      if response.code == "200"
        weather_data = JSON.parse(response.body)
        @logger.info "weatherData: #{weather_data}"
        
        return {
          weather_data: weather_data
        }
      else
        raise "Weather API returned error: #{response.code}"
      end
    rescue => e
      @logger.error "Error fetching weather data: #{e.message}"
      raise e
    end
  end
  
  # Add an event to the session queue
  def add_event_to_session_queue(session_id, event)
    session_data = @active_sessions[session_id]
    return unless session_data && session_data[:is_active]
    
    update_session_activity(session_id)
    
    # Check if event is already a JSON string
    if event.is_a?(String)
      json_event = event
    else
      json_event = event.to_json
    end
    
    session_data[:queue_mutex].synchronize do
      session_data[:queue] << json_event
    end
    
    # Signal that we have a new event (set and reset aren't needed)
    session_data[:queue_signal].set
  end
  
  # Setup initial session start event
  def setup_session_start_event(session_id)
    @logger.info "Setting up initial events for session #{session_id}..."
    session_data = @active_sessions[session_id]
    return unless session_data
    
    # Session start event with same format as example.rb
    add_event_to_session_queue(session_id, {
      event: {
        sessionStart: {
          inferenceConfiguration: {
            maxTokens: 10000, 
            topP: 0.95,
            temperature: 0.9
          }
        }
      }
    })
  end
  
  # Setup prompt start event
  def setup_prompt_start_event(session_id)
    @logger.info "Setting up prompt start event for session #{session_id}..."
    session_data = @active_sessions[session_id]
    return unless session_data
    
    # Prompt start event
    add_event_to_session_queue(session_id, {
      event: {
        promptStart: {
          promptName: session_data[:prompt_name],
          textOutputConfiguration: {
            mediaType: "text/plain"
          },
          audioOutputConfiguration: DEFAULT_AUDIO_OUTPUT_CONFIGURATION,
          toolUseOutputConfiguration: {
            mediaType: "application/json"
          },
          toolConfiguration: {
            tools: [
              {
                toolSpec: {
                  name: "getDateAndTimeTool",
                  description: "Get information about the current date and time.",
                  inputSchema: {
                    json: DEFAULT_TOOL_SCHEMA
                  }
                }
              },
              {
                toolSpec: {
                  name: "getWeatherTool",
                  description: "Get the current weather for a given location, based on its WGS84 coordinates.",
                  inputSchema: {
                    json: WEATHER_TOOL_SCHEMA
                  }
                }
              }
            ]
          }
        }
      }
    })
    
    session_data[:is_prompt_start_sent] = true
  end
  
  # Setup system prompt event
  def setup_system_prompt_event(session_id, text_config = DEFAULT_TEXT_CONFIGURATION, system_prompt_content = DEFAULT_SYSTEM_PROMPT)
    @logger.info "Setting up systemPrompt events for session #{session_id}..."
    session_data = @active_sessions[session_id]
    return unless session_data
    
    # Text content start
    text_prompt_id = SecureRandom.uuid
    add_event_to_session_queue(session_id, {
      event: {
        contentStart: {
          promptName: session_data[:prompt_name],
          contentName: text_prompt_id,
          type: "TEXT",
          interactive: true,
          textInputConfiguration: {
            mediaType: "text/plain"
          }
        }
      }
    })
    
    # Text input content
    add_event_to_session_queue(session_id, {
      event: {
        textInput: {
          promptName: session_data[:prompt_name],
          contentName: text_prompt_id,
          content: system_prompt_content,
          role: "SYSTEM"
        }
      }
    })
    
    # Text content end
    add_event_to_session_queue(session_id, {
      event: {
        contentEnd: {
          promptName: session_data[:prompt_name],
          contentName: text_prompt_id
        }
      }
    })
  end
  
  # Setup start audio event
  def setup_start_audio_event(session_id, audio_config = DEFAULT_AUDIO_INPUT_CONFIGURATION)
    @logger.info "Setting up startAudioContent event for session #{session_id}..."
    session_data = @active_sessions[session_id]
    return unless session_data
    
    @logger.info "Using audio content ID: #{session_data[:audio_content_id]}"
    
    # Audio content start
    add_event_to_session_queue(session_id, {
      event: {
        contentStart: {
          promptName: session_data[:prompt_name],
          contentName: session_data[:audio_content_id],
          type: "AUDIO",
          interactive: true,
          audioInputConfiguration: audio_config
        }
      }
    })
    
    session_data[:is_audio_content_start_sent] = true
    @logger.info "Initial events setup complete for session #{session_id}"
  end
  
  # Stream audio chunk - simplified to match example.rb
  def stream_audio_chunk(session_id, audio_data)
    session_data = @active_sessions[session_id]
    
    # Check if session exists and is active
    if !session_data || !session_data[:is_active]
      @logger.error "Session #{session_id} not found or inactive"
      raise "Session not active or not found: #{session_id}"
    end
    
    # Verify we have an input stream available
    if !session_data[:input_stream]
      @logger.error "No input stream available for session #{session_id}"
      raise "No input stream available for session: #{session_id}"
    end
    
    # Validate audio data
    if audio_data.nil? || audio_data.empty?
      @logger.error "Empty audio data received for session #{session_id}"
      raise "Empty audio data received"
    end
    
    # Convert audio to base64
    base64_data = Base64.strict_encode64(audio_data)
    
    # Create the audio event in the exact format used in example.rb
    audio_event = {
      "event": {
        "audioInput": {
          "promptName": session_data[:prompt_name],
          "contentName": session_data[:audio_content_id],
          "content": base64_data,
          "role": "USER"
        }
      }
    }.to_json
    
    begin
      # Send directly to the input stream
      session_data[:input_stream].signal_chunk_event(bytes: audio_event)
    rescue => e
      @logger.error "Failed to send audio chunk: #{e.message}"
      
      # If connection is closed, mark session as inactive
      if e.message.include?("Connection is closed")
        @logger.error "Connection closed for session #{session_id}, marking as inactive"
        session_data[:is_active] = false
        dispatch_event_for_session(session_id, 'error', {
          source: 'connection',
          error: "Connection closed: #{e.message}",
          recovery: "Please create a new session"
        })
      end
      
      raise "Failed to send audio: #{e.message}"
    end
  end
  
  # Send tool result
  def send_tool_result(session_id, tool_use_id, result)
    session_data = @active_sessions[session_id]
    return unless session_data && session_data[:is_active]
    
    @logger.info "Sending tool result for session #{session_id}, tool use ID: #{tool_use_id}"
    content_id = SecureRandom.uuid
    
    # Tool content start
    add_event_to_session_queue(session_id, {
      event: {
        contentStart: {
          promptName: session_data[:prompt_name],
          contentName: content_id,
          interactive: false,
          type: "TOOL",
          role: "TOOL",
          toolResultInputConfiguration: {
            toolUseId: tool_use_id,
            type: "TEXT",
            textInputConfiguration: {
              mediaType: "text/plain"
            }
          }
        }
      }
    })
    
    # Tool content input
    result_content = result.is_a?(String) ? result : result.to_json
    add_event_to_session_queue(session_id, {
      event: {
        toolResult: {
          promptName: session_data[:prompt_name],
          contentName: content_id,
          content: result_content
        }
      }
    })
    
    # Tool content end
    add_event_to_session_queue(session_id, {
      event: {
        contentEnd: {
          promptName: session_data[:prompt_name],
          contentName: content_id
        }
      }
    })
    
    @logger.info "Tool result sent for session #{session_id}"
  end
  
  # Send content end
  def send_content_end(session_id)
    session_data = @active_sessions[session_id]
    return unless session_data && session_data[:is_active]
    
    # Check if we have a valid input stream
    if !session_data[:input_stream]
      @logger.error "No input stream available for content end in session #{session_id}"
      return
    end
    
    event = {
      "event": {
        "contentEnd": {
          "promptName": session_data[:prompt_name],
          "contentName": session_data[:audio_content_id]
        }
      }
    }.to_json
    
    begin
      session_data[:input_stream].signal_chunk_event(bytes: event)
    rescue => e
      @logger.error "Error sending content end: #{e.message}"
      
      # If connection is closed, mark session as inactive
      if e.message.include?("Connection is closed")
        @logger.error "Connection closed for session #{session_id}, marking as inactive"
        session_data[:is_active] = false
      end
    end
  end
  
  # Send prompt end
  def send_prompt_end(session_id)
    session_data = @active_sessions[session_id]
    return unless session_data && session_data[:is_active]
    
    # Check if we have a valid input stream
    if !session_data[:input_stream]
      @logger.error "No input stream available for prompt end in session #{session_id}"
      return
    end
    
    event = {
      "event": {
        "promptEnd": {
          "promptName": session_data[:prompt_name]
        }
      }
    }.to_json
    
    begin
      session_data[:input_stream].signal_chunk_event(bytes: event)
    rescue => e
      @logger.error "Error sending prompt end: #{e.message}"
      
      # If connection is closed, mark session as inactive
      if e.message.include?("Connection is closed")
        @logger.error "Connection closed for session #{session_id}, marking as inactive"
        session_data[:is_active] = false
      end
    end
  end
  
  # Send session end
  def send_session_end(session_id)
    session_data = @active_sessions[session_id]
    return unless session_data && session_data[:is_active]
    
    # Check if we have a valid input stream
    if !session_data[:input_stream]
      @logger.error "No input stream available for session end in session #{session_id}"
      session_data[:is_active] = false
      @active_sessions.delete(session_id)
      @session_last_activity.delete(session_id)
      return
    end
    
    event = {
      "event": {
        "sessionEnd": {}
      }
    }.to_json
    
    begin
      session_data[:input_stream].signal_chunk_event(bytes: event)
      
      # Close the input stream
      session_data[:input_stream].signal_end_stream
      
      # Clean up
      session_data[:is_active] = false
      @active_sessions.delete(session_id)
      @session_last_activity.delete(session_id)
    rescue => e
      @logger.error "Error sending session end: #{e.message}"
      
      # Ensure cleanup happens even if there's an error
      session_data[:is_active] = false
      @active_sessions.delete(session_id)
      @session_last_activity.delete(session_id)
    end
  end
  
  # Dispatch events to handlers for a specific session
  def dispatch_event_for_session(session_id, event_type, data)
    session_data = @active_sessions[session_id]
    return unless session_data
    
    stream_session = session_data[:stream_session]
    return unless stream_session
    
    begin
      stream_session.handle_event(event_type, data)
    rescue => e
      @logger.error "Error dispatching event #{event_type}: #{e.message}"
    end
  end
  
  # Close session
  def close_session(session_id)
    return if is_cleanup_in_progress(session_id)
    
    @session_cleanup_in_progress.add(session_id)
    begin
      @logger.info "Starting close process for session #{session_id}"
      send_content_end(session_id)
      send_prompt_end(session_id)
      send_session_end(session_id)
      @logger.info "Session #{session_id} cleanup complete"
    rescue => e
      @logger.error "Error during closing sequence for session #{session_id}: #{e.message}"
      
      # Ensure cleanup happens even if there's an error
      session_data = @active_sessions[session_id]
      if session_data
        session_data[:is_active] = false
        @active_sessions.delete(session_id)
        @session_last_activity.delete(session_id)
      end
    ensure
      @session_cleanup_in_progress.delete(session_id)
    end
  end
  
  # Force close session
  def force_close_session(session_id)
    return if is_cleanup_in_progress(session_id) || !@active_sessions.key?(session_id)
    
    @session_cleanup_in_progress.add(session_id)
    begin
      session_data = @active_sessions[session_id]
      return unless session_data
      
      @logger.info "Force closing session #{session_id}"
      
      # Immediately mark as inactive and clean up resources
      session_data[:is_active] = false
      # Set the close signal to notify waiting threads
      session_data[:close_signal].set
      @active_sessions.delete(session_id)
      @session_last_activity.delete(session_id)
      
      @logger.info "Session #{session_id} force closed"
    ensure
      @session_cleanup_in_progress.delete(session_id)
    end
  end
end 