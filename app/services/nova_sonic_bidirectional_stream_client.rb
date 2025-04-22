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
    voiceId: 'en_us_matthew',
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
      @is_processing_audio = false
      @audio_buffer_queue = []
      @max_queue_size = 200
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
    
    # Stream audio for this session
    def stream_audio(audio_data)
      return unless @is_active
      
      # Check queue size to avoid memory issues
      if @audio_buffer_queue.length >= @max_queue_size
        # Queue is full, drop oldest chunk
        @audio_buffer_queue.shift
        @logger.info "Audio queue full, dropping oldest chunk"
      end
      
      # Queue the audio chunk for streaming
      @audio_buffer_queue.push(audio_data)
      process_audio_queue
    end
    
    # Process audio queue for continuous streaming
    def process_audio_queue
      return if @is_processing_audio || @audio_buffer_queue.empty? || !@is_active
      
      @is_processing_audio = true
      begin
        # Process all chunks in the queue, up to a reasonable limit
        processed_chunks = 0
        max_chunks_per_batch = 5 # Process max 5 chunks at a time to avoid overload
        
        while !@audio_buffer_queue.empty? && processed_chunks < max_chunks_per_batch && @is_active
          audio_chunk = @audio_buffer_queue.shift
          if audio_chunk
            client.stream_audio_chunk(session_id, audio_chunk)
            processed_chunks += 1
          end
        end
      ensure
        @is_processing_audio = false
        
        # If there are still items in the queue, schedule the next processing
        if !@audio_buffer_queue.empty? && @is_active
          Thread.new { process_audio_queue }
        end
      end
    end
    
    def end_audio_content
      return unless @is_active
      client.send_content_end(session_id)
    end
    
    def end_prompt
      return unless @is_active
      client.send_prompt_end(session_id)
    end
    
    def close
      return unless @is_active
      
      @is_active = false
      @audio_buffer_queue.clear # Clear any pending audio
      
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
      http_wire_trace: true, # Enable HTTP tracing for debugging
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
  
  # Initiate a bidirectional stream session
  def initiate_session(session_id)
    session_data = @active_sessions[session_id]
    if !session_data
      raise "Stream session #{session_id} not found"
    end
    
    begin
      # Create all events first exactly matching example.rb
      @logger.info "Setting up events sequence for session #{session_id}..."
      
      # Create an array of events to send in precise order
      events = []
      
      # 1. Session start event
      events << {
        event: {
          sessionStart: {
            inferenceConfiguration: {
              maxTokens: 10000,
              topP: 0.95,
              temperature: 0.9
            }
          }
        }
      }.to_json
      
      # 2. Prompt start event
      events << {
        event: {
          promptStart: {
            promptName: session_data[:prompt_name],
            textOutputConfiguration: {
              mediaType: "text/plain"
            },
            audioOutputConfiguration: {
              mediaType: "audio/lpcm",
              sampleRateHertz: 24000,
              sampleSizeBits: 16,
              channelCount: 1,
              voiceId: "en_us_matthew",
              encoding: "base64",
              audioType: "SPEECH"
            },
            toolUseOutputConfiguration: {
              mediaType: "application/json"
            },
            toolConfiguration: {
              tools: []
            }
          }
        }
      }.to_json
      
      # 3. Content start for text (system prompt)
      text_content_id = SecureRandom.uuid
      events << {
        event: {
          contentStart: {
            promptName: session_data[:prompt_name],
            contentName: text_content_id,
            type: "TEXT",
            interactive: true,
            textInputConfiguration: {
              mediaType: "text/plain"
            }
          }
        }
      }.to_json
      
      # 4. Text input (system prompt)
      events << {
        event: {
          textInput: {
            promptName: session_data[:prompt_name],
            contentName: text_content_id,
            content: DEFAULT_SYSTEM_PROMPT,
            role: "SYSTEM"
          }
        }
      }.to_json
      
      # 5. Content end for text
      events << {
        event: {
          contentEnd: {
            promptName: session_data[:prompt_name],
            contentName: text_content_id
          }
        }
      }.to_json
      
      # 6. Content start for audio
      events << {
        event: {
          contentStart: {
            promptName: session_data[:prompt_name],
            contentName: session_data[:audio_content_id],
            type: "AUDIO",
            interactive: true,
            audioInputConfiguration: {
              mediaType: "audio/lpcm",
              sampleRateHertz: 16000,
              sampleSizeBits: 16,
              channelCount: 1,
              audioType: "SPEECH",
              encoding: "base64"
            }
          }
        }
      }.to_json
      
      # Start the bidirectional stream
      start_bidirectional_stream(session_id, events)
      
    rescue => e
      @logger.error "Error in session #{session_id}: #{e.message}"
      @logger.error e.backtrace.join("\n")
      dispatch_event_for_session(session_id, 'error', {
        source: 'bidirectional_stream',
        error: e.message
      })
      
      # Make sure to clean up if there's an error
      if session_data[:is_active]
        close_session(session_id)
      end
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
        puts "GOT OUTPUT EVENT FROM BEDROCK: #{event.inspect}"
        
        if event.is_a?(Hash) && event.key?(:event_type)
          event_type = event[:event_type]
          
          if event_type == :chunk
            begin
              if event[:bytes]
                puts "Processing chunk event with bytes: #{event[:bytes][0..100]}..." 
                json_response = JSON.parse(event[:bytes])
                puts "Parsed JSON: #{json_response.inspect[0..200]}..."
                process_response(session_id, json_response)
              else
                puts "Received chunk event without bytes!"
              end
            rescue JSON::ParserError => e
              @logger.error "Failed to parse JSON response: #{e.message}"
              puts "Failed to parse JSON response: #{e.message}"
              puts "Raw bytes: #{event[:bytes]}" if event[:bytes]
            end
          elsif event_type == :error
            @logger.error "Stream error for session #{session_id}: #{event[:error]}"
            puts "Stream error for session #{session_id}: #{event[:error]}"
            dispatch_event_for_session(session_id, 'error', {
              source: 'stream',
              error: event[:error]
            })
          elsif event_type == :model_stream_error_exception
            message = event.respond_to?(:message) ? event.message : "Unknown model stream error"
            @logger.error "Model stream error for session #{session_id}: #{message}"
            puts "Model stream error for session #{session_id}: #{message}"
            
            # Mark session for cleanup
            session_data[:is_active] = false
            
            # Dispatch detailed error event
            dispatch_event_for_session(session_id, 'error', {
              source: 'model_stream',
              error: message,
              details: "AWS Bedrock returned a model stream error. This typically indicates an issue with the model or the input data format. Please check your audio format and AWS credentials."
            })
          elsif event_type == :initial_response
            puts "Received initial_response event: #{event.inspect}"
          elsif event_type == :complete
            puts "Received complete event: #{event.inspect}"
          else
            puts "Unhandled event type: #{event_type}, data: #{event.inspect}"
          end
        else
          puts "Received non-standard event: #{event.inspect}"
          
          # Try to extract error information if it's an exception
          if event.is_a?(Struct) && event.respond_to?(:message)
            error_message = event.message
            @logger.error "Non-standard error in stream for session #{session_id}: #{error_message}"
            
            # Mark session for cleanup
            session_data[:is_active] = false
            
            # Dispatch detailed error event
            dispatch_event_for_session(session_id, 'error', {
              source: 'aws_bedrock',
              error: error_message,
              details: "AWS Bedrock returned an error. This could be due to expired credentials, invalid audio format, or service issues."
            })
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
      puts "Starting to send queued events for session #{session_id}"
      # First send all initially queued events
      session_data[:queue_mutex].synchronize do
        puts "Initial queue has #{session_data[:queue].size} events"
        session_data[:queue].each_with_index do |event, index|
          # Events should already be JSON strings now
          event_json = event
          puts "Sending initial event #{index+1}/#{session_data[:queue].size} to Bedrock (length: #{event_json.length})"
          puts "Event content (truncated): #{event_json[0..300]}..." if event_json.length > 300
          
          begin
            input_stream.signal_chunk_event(bytes: event_json)
            puts "Successfully sent event #{index+1}"
          rescue => e
            puts "Error sending event #{index+1}: #{e.message}"
            puts e.backtrace.join("\n")
            raise # Re-raise to exit the loop
          end
        end
        session_data[:queue].clear
        puts "Cleared initial queue after sending events"
      end
      
      # Then wait for new events or close signal
      puts "Starting event loop to wait for additional events"
      loop_count = 0
      loop do
        loop_count += 1
        
        if !session_data[:is_active]
          puts "Session #{session_id} is no longer active, exiting event loop"
          break
        end
        
        # Replace Concurrent::Select with a simpler approach using Concurrent::Event#wait
        # with a timeout to periodically check if we should still be running
        if (loop_count % 100) == 0
          puts "Still waiting for events in loop (iteration #{loop_count})"
        end
        
        event_triggered = session_data[:queue_signal].wait(0.1)
        
        # Check if we should close
        if !session_data[:is_active] || session_data[:close_signal].set?
          puts "Detected close signal or inactive session, exiting event loop"
          break
        end
        
        # Process any new events in the queue
        if event_triggered
          session_data[:queue_mutex].synchronize do
            queue_size = session_data[:queue].size
            return if queue_size == 0

            puts "Processing #{queue_size} new events"
            
            processed = 0
            while session_data[:is_active] && !session_data[:queue].empty?
              event = session_data[:queue].shift
              processed += 1
              
              event_json = event.to_json
              puts "Sending queued event #{processed}/#{queue_size} (length: #{event_json.length})"
              
              begin
                input_stream.signal_chunk_event(bytes: event_json)
                puts "Successfully sent queued event #{processed}"
              rescue => e
                puts "Error sending queued event: #{e.message}"
                puts e.backtrace.join("\n")
                # Don't re-raise here to allow processing of other events
              end
            end
          end
        end
      end
      
      puts "Event loop for session #{session_id} completed"
    rescue => e
      puts "Critical error in send_queued_events for session #{session_id}: #{e.message}"
      puts e.backtrace.join("\n")
      @logger.error "Error in send_queued_events for session #{session_id}: #{e.message}"
    end
  end
  
  # Process response from AWS Bedrock
  def process_response(session_id, response)
    session_data = @active_sessions[session_id]
    return unless session_data && session_data[:is_active]
    
    update_session_activity(session_id)
    
    begin
      puts "Processing response for session #{session_id}: #{response.inspect[0..300]}..."
      
      if response['event']
        puts "Event type: #{response['event'].keys.first}" if response['event'].keys.any?
        
        if response['event']['contentStart']
          puts "Dispatching contentStart event"
          dispatch_event_for_session(session_id, 'contentStart', response['event']['contentStart'])
        elsif response['event']['textOutput']
          puts "Dispatching textOutput event: #{response['event']['textOutput']['content']}"
          dispatch_event_for_session(session_id, 'textOutput', response['event']['textOutput'])
        elsif response['event']['audioOutput']
          content_length = response['event']['audioOutput']['content'].length
          puts "Dispatching audioOutput event (#{content_length} bytes)"
          dispatch_event_for_session(session_id, 'audioOutput', response['event']['audioOutput'])
        elsif response['event']['toolUse']
          puts "Dispatching toolUse event"
          dispatch_event_for_session(session_id, 'toolUse', response['event']['toolUse'])
          
          # Store tool use information for later
          session_data[:tool_use_content] = response['event']['toolUse']
          session_data[:tool_use_id] = response['event']['toolUse']['toolUseId']
          session_data[:tool_name] = response['event']['toolUse']['toolName']
        elsif response['event']['contentEnd'] && response['event']['contentEnd']['type'] == 'TOOL'
          # Process tool use
          puts "Processing tool use for session #{session_id}"
          @logger.info "Processing tool use for session #{session_id}"
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
            puts "Error processing tool use: #{e.message}"
            @logger.error "Error processing tool use: #{e.message}"
            dispatch_event_for_session(session_id, 'error', {
              source: 'tool_use',
              error: e.message
            })
          end
        elsif response['event']['contentEnd']
          puts "Dispatching contentEnd event"
          dispatch_event_for_session(session_id, 'contentEnd', response['event']['contentEnd'])
        else
          # Handle other events
          event_keys = response['event'].keys
          if !event_keys.empty?
            puts "Dispatching #{event_keys.first} event"
            dispatch_event_for_session(session_id, event_keys.first, response['event'])
          else
            puts "Dispatching unknown event"
            dispatch_event_for_session(session_id, 'unknown', response)
          end
        end
      else
        puts "Response doesn't contain 'event' key: #{response.inspect}"
      end
    rescue => e
      puts "Error processing response for session #{session_id}: #{e.message}"
      puts e.backtrace.join("\n")
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
  
  # Stream audio chunk
  def stream_audio_chunk(session_id, audio_data)
    session_data = @active_sessions[session_id]
    if !session_data || !session_data[:is_active] || !session_data[:audio_content_id]
      raise "Invalid session #{session_id} for audio streaming"
    end
    
    # Validate audio data
    if audio_data.nil? || audio_data.empty?
      @logger.error "Empty audio data received for session #{session_id}"
      raise "Empty audio data received"
    end
    
    # Check if audio data looks like valid PCM data
    begin
      # Try to read a sample of the audio data
      sample_rate = 16000 # Expected from DEFAULT_AUDIO_INPUT_CONFIGURATION
      sample_size = 2     # 16-bit audio = 2 bytes per sample
      num_samples = [10, audio_data.size / sample_size].min
      
      if num_samples > 0
        @logger.debug "Audio data sample (#{num_samples} samples): #{audio_data.byteslice(0, num_samples * sample_size).unpack('s*').inspect}"
      end
    rescue => e
      @logger.warn "Could not analyze audio data: #{e.message}"
    end
    
    # Convert audio to base64
    base64_data = Base64.strict_encode64(audio_data)
    
    # Log audio data length for debugging
    @logger.info "Adding audio chunk (#{audio_data.size} bytes raw, #{base64_data.length} bytes base64) to queue for session #{session_id}"
    
    # Create the event payload - this matches the format in example.rb
    audio_event = {
      event: {
        audioInput: {
          promptName: session_data[:prompt_name],
          contentName: session_data[:audio_content_id],
          content: base64_data,
          role: "USER"
        }
      }
    }.to_json
    
    begin
      # If we have an input stream, send the audio data directly
      if session_data[:input_stream]
        session_data[:input_stream].signal_chunk_event(bytes: audio_event)
        @logger.debug "Audio chunk directly sent to AWS for session #{session_id}"
      else
        # Otherwise queue it for later
        add_event_to_session_queue(session_id, audio_event)
        @logger.debug "Audio chunk queued for session #{session_id}"
      end
    rescue => e
      @logger.error "Failed to send audio chunk for session #{session_id}: #{e.message}"
      @logger.error e.backtrace.join("\n")
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
    return unless session_data && session_data[:is_audio_content_start_sent]
    
    puts "Sending contentEnd for session #{session_id}"
    
    add_event_to_session_queue(session_id, {
      event: {
        contentEnd: {
          promptName: session_data[:prompt_name],
          contentName: session_data[:audio_content_id]
        }
      }
    })
    
    # Give a small delay to ensure it's processed
    puts "Waiting for contentEnd to be processed..."
    sleep(0.5)
    puts "ContentEnd wait completed"
  end
  
  # Send prompt end
  def send_prompt_end(session_id)
    session_data = @active_sessions[session_id]
    return unless session_data && session_data[:is_prompt_start_sent]
    
    puts "Sending promptEnd for session #{session_id}"
    
    add_event_to_session_queue(session_id, {
      event: {
        promptEnd: {
          promptName: session_data[:prompt_name]
        }
      }
    })
    
    # Give a small delay to ensure it's processed
    puts "Waiting for promptEnd to be processed..."
    sleep(0.3)
    puts "PromptEnd wait completed"
  end
  
  # Send session end
  def send_session_end(session_id)
    session_data = @active_sessions[session_id]
    return unless session_data
    
    puts "Sending sessionEnd for session #{session_id}"
    
    add_event_to_session_queue(session_id, {
      event: {
        sessionEnd: {}
      }
    })
    
    # Give a small delay to ensure it's processed
    puts "Waiting for sessionEnd to be processed..."
    sleep(0.3)
    puts "SessionEnd wait completed"
    
    # Explicitly tell the input stream to close
    if session_data[:input_stream]
      puts "Signaling end of input stream for session #{session_id}"
      begin
        session_data[:input_stream].signal_end_stream
        puts "Successfully signaled end of input stream"
      rescue => e
        puts "Error signaling end of input stream: #{e.message}"
      end
    else
      puts "No input stream available to signal end for session #{session_id}"
    end
    
    # Now it's safe to clean up
    session_data[:is_active] = false
    # Set the close signal to notify waiting threads
    session_data[:close_signal].set
    @active_sessions.delete(session_id)
    @session_last_activity.delete(session_id)
    @logger.info "Session #{session_id} closed and removed from active sessions"
  end
  
  # Dispatch events to handlers for a specific session
  def dispatch_event_for_session(session_id, event_type, data)
    session_data = @active_sessions[session_id]
    if !session_data
      puts "Cannot dispatch event: session #{session_id} not found"
      return
    end
    
    stream_session = session_data[:stream_session]
    if !stream_session
      puts "Cannot dispatch event: stream_session for #{session_id} not found"
      return
    end
    
    puts "Dispatching event #{event_type} to handlers for session #{session_id}"
    begin
      stream_session.handle_event(event_type, data)
      puts "Event #{event_type} dispatched successfully"
    rescue => e
      puts "Error dispatching event #{event_type}: #{e.message}"
      puts e.backtrace.join("\n")
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