require 'aws-sdk-bedrockruntime'
require 'easy_audio'
require 'securerandom'
require 'base64'
require 'json'
require 'thread'

class NovaSonic
  # Configuration
  MIC_SAMPLE_RATE = 16000
  MIC_CHANNELS = 1
  MIC_BITS_PER_SAMPLE = 16
  MIC_FRAMES_PER_BUFFER = 1024

  SPEAKER_SAMPLE_RATE = 24000
  SPEAKER_CHANNELS = 1
  SPEAKER_BITS_PER_SAMPLE = 16

  def initialize(model_id: 'amazon.nova-sonic-v1:0', region: 'us-east-1')
    @model_id = model_id
    @region = region
    @is_active = false
    @prompt_id = SecureRandom.uuid
    @content_id = SecureRandom.uuid
    @audio_content_id = SecureRandom.uuid
    @speaker_samples = []
    @buffer_mutex = Mutex.new
    @mic_buffer = []
    @last_mic_time = Time.now
    @role = nil
    @display_assistant_text = false
    
    # Echo test variables
    @echo_test_mode = false
    @echo_buffer = []
    @echo_start_time = nil
    
    # Initialize AWS client
    @async_client = Aws::BedrockRuntime::AsyncClient.new(region: region, enable_alpn: true)
    @input_stream = Aws::BedrockRuntime::EventStreams::InvokeModelWithBidirectionalStreamInput.new
    @output_stream = Aws::BedrockRuntime::EventStreams::InvokeModelWithBidirectionalStreamOutput.new
    
    setup_output_handler
  end
  
  def setup_output_handler
    # Handle output from Bedrock
    @output_stream.on_event do |e|
      if e[:event_type] == :chunk
        begin
          # Parse the JSON response
          response = JSON.parse(e[:bytes])
          if response['event'] && response['event']['audioOutput']
            # Decode base64 audio content
            audio_data = Base64.strict_decode64(response['event']['audioOutput']['content'])
            
            # Add decoded audio to buffer
            @buffer_mutex.synchronize do
              @speaker_samples.concat(audio_data.unpack('s*'))
            end
          end
          
          # Handle content start event to track role
          if response['event'] && response['event']['contentStart']
            content_start = response['event']['contentStart']
            @role = content_start['role'] if content_start['role']
            
            # Check for speculative content
            if content_start['additionalModelFields']
              begin
                additional_fields = JSON.parse(content_start['additionalModelFields'])
                @display_assistant_text = additional_fields['generationStage'] == 'SPECULATIVE'
              rescue
                @display_assistant_text = false
              end
            end
          end
          
          # Print any text output for debugging
          if response['event'] && response['event']['textOutput']
            text = response['event']['textOutput']['text']
            if @role == "ASSISTANT" && @display_assistant_text
              puts "Assistant: #{text}"
            elsif @role == "USER"
              puts "User: #{text}"
            end
          end
        rescue JSON::ParserError => e
          puts "Failed to parse JSON: #{e}"
        rescue => e
          puts "Error processing output: #{e}"
        end
      end
    end
  end
  
  def start_session
    @is_active = true
    
    # Initialize the stream
    @async_resp = @async_client.invoke_model_with_bidirectional_stream(
      model_id: @model_id,
      input_event_stream_handler: @input_stream,
      output_event_stream_handler: @output_stream
    )
    
    # Send session start event
    session_start = {
      "event": {
        "sessionStart": {
          "inferenceConfiguration": {
            "maxTokens": 1024,
            "topP": 0.9,
            "temperature": 0.7
          }
        }
      }
    }.to_json
    @input_stream.signal_chunk_event(bytes: session_start)
    
    # Send prompt start event
    prompt_start = {
      "event": {
        "promptStart": {
          "promptName": @prompt_id,
          "textOutputConfiguration": {
            "mediaType": "text/plain"
          },
          "audioOutputConfiguration": {
            "mediaType": "audio/lpcm",
            "sampleRateHertz": SPEAKER_SAMPLE_RATE,
            "sampleSizeBits": SPEAKER_BITS_PER_SAMPLE,
            "channelCount": SPEAKER_CHANNELS,
            "voiceId": "matthew",
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
    }.to_json
    @input_stream.signal_chunk_event(bytes: prompt_start)
    
    # Send system prompt
    text_content_start = {
      "event": {
        "contentStart": {
          "promptName": @prompt_id,
          "contentName": @content_id,
          "type": "TEXT",
          "interactive": true,
          "role": "SYSTEM",
          "textInputConfiguration": {
            "mediaType": "text/plain"
          }
        }
      }
    }.to_json
    @input_stream.signal_chunk_event(bytes: text_content_start)
    
    system_prompt = {
      "event": {
        "textInput": {
          "promptName": @prompt_id,
          "contentName": @content_id,
          "content": "You are a friendly assistant. The user and you will engage in a spoken dialog exchanging the transcripts of a natural real-time conversation. Keep your responses short, generally two or three sentences for chatty scenarios."
        }
      }
    }.to_json
    @input_stream.signal_chunk_event(bytes: system_prompt)
    
    text_content_end = {
      "event": {
        "contentEnd": {
          "promptName": @prompt_id,
          "contentName": @content_id
        }
      }
    }.to_json
    @input_stream.signal_chunk_event(bytes: text_content_end)
  end
  
  def start_audio_input
    # Start Audio Stream
    audio_content_start = {
      "event": {
        "contentStart": {
          "promptName": @prompt_id,
          "contentName": @audio_content_id,
          "type": "AUDIO",
          "interactive": true,
          "role": "USER",
          "audioInputConfiguration": {
            "mediaType": "audio/lpcm",
            "sampleRateHertz": MIC_SAMPLE_RATE,
            "sampleSizeBits": MIC_BITS_PER_SAMPLE,
            "channelCount": MIC_CHANNELS,
            "audioType": "SPEECH",
            "encoding": "base64"
          }
        }
      }
    }.to_json
    @input_stream.signal_chunk_event(bytes: audio_content_start)
  end
  
  def send_audio_chunk(audio_data)
    return unless @is_active
    
    # Format for sending to Bedrock
    event = {
      "event": {
        "audioInput": {
          "promptName": @prompt_id,
          "contentName": @audio_content_id,
          "content": audio_data,
          "role": "USER"
        }
      }
    }.to_json
    
    @input_stream.signal_chunk_event(bytes: event)
  end
  
  def end_audio_input
    return unless @is_active
    
    audio_content_end = {
      "event": {
        "contentEnd": {
          "promptName": @prompt_id,
          "contentName": @audio_content_id
        }
      }
    }.to_json
    @input_stream.signal_chunk_event(bytes: audio_content_end)
  end
  
  def end_session
    return unless @is_active
    
    prompt_end = {
      "event": {
        "promptEnd": {
          "promptName": @prompt_id
        }
      }
    }.to_json
    @input_stream.signal_chunk_event(bytes: prompt_end)
    
    session_end = {
      "event": {
        "sessionEnd": {}
      }
    }.to_json
    @input_stream.signal_chunk_event(bytes: session_end)
    
    @is_active = false
  end
  
  def start_echo_test
    puts "Starting echo test - Recording for 3 seconds then playing back audio..."
    @echo_test_mode = true
    @echo_buffer = []
    @echo_start_time = Time.now
  end
  
  def stop_echo_test
    @echo_test_mode = false
    puts "Echo test stopped."
  end
  
  def start_audio_stream
    puts "Initializing audio..."
    puts "Starting microphone input and speaker output..."
    
    # Using the easy_open method as shown in GitHub documentation
    begin
      stream_options = {
        in: true,             # Enable microphone input
        out: true,            # Enable speaker output
        in_sample_rate: MIC_SAMPLE_RATE,
        out_sample_rate: SPEAKER_SAMPLE_RATE,
        in_channels: MIC_CHANNELS,
        out_channels: SPEAKER_CHANNELS,
        latency: 0.1,         # Low latency
        on_error: ->(err) { puts "Audio error: #{err}"; @is_active = false }
      }
      
      puts "Starting audio stream with options: #{stream_options}"
      @stream = EasyAudio.easy_open(stream_options) do |input_sample|
        # Exit the block if we're no longer running
        next 0.0 unless @is_active
        
        # Input handling (when we receive a sample from the microphone)
        if input_sample
          # Convert float (-1.0 to 1.0) to integer
          sample_int = (input_sample * 32767).to_i
          @mic_buffer << sample_int
          
          # If in echo test mode, store audio for playback
          if @echo_test_mode
            @echo_buffer << sample_int
            
            # After 3 seconds, switch to playback
            if Time.now - @echo_start_time >= 3.0
              puts "Recording complete. Playing back recorded audio..."
              @echo_test_mode = false
              
              # Copy echo buffer to speaker buffer for playback
              @buffer_mutex.synchronize do
                @speaker_samples = @echo_buffer.dup
              end
              
              puts "Playback complete. Echo test successful!"
            end
          else
            # Normal operation - send to Bedrock after buffer fills
            if @mic_buffer.size >= MIC_FRAMES_PER_BUFFER && (Time.now - @last_mic_time) >= 0.1
              if @is_active
                begin
                  # Pack into binary and encode
                  binary_data = @mic_buffer.pack('s*')
                  encoded_data = Base64.strict_encode64(binary_data)
                  
                  # Send to Bedrock
                  send_audio_chunk(encoded_data)
                  
                  # Update time and clear buffer
                  @last_mic_time = Time.now
                  @mic_buffer.clear
                rescue => e
                  puts "Error sending audio: #{e.message}"
                end
              end
            end
          end
        end
        
        # Output handling (returning the next sample to play)
        @buffer_mutex.synchronize do
          if @speaker_samples.empty?
            # Return silence if no samples available
            0.0
          else
            # Get the next sample and convert from int16 to float
            @speaker_samples.shift / 32768.0
          end
        end
      end
      
      puts "Audio streaming started. Speak into your microphone..."
      puts "Press Ctrl+C to exit or 'e' to run an echo test."
      
      # Start a thread to listen for 'e' key press to trigger echo test
      Thread.new do
        while @is_active
          input = STDIN.getch rescue nil
          if input == 'e'
            start_echo_test
          end
        end
      end
      
      return @stream
    rescue => e
      puts "Failed to open audio stream: #{e.message}"
      puts e.backtrace.join("\n")
      @is_active = false
      return nil
    end
  end
  
  def shutdown
    puts "\nShutting down..."
    @is_active = false
    
    # Send a content end event to close the stream properly
    begin
      puts "Attempting to close content and prompt streams..."
      
      # Try to send a clean content end event
      begin
        end_audio_input
      rescue => e
        puts "Warning: Error sending content end event: #{e.message}"
      end
      
      # Try to send a clean prompt end event
      begin
        end_session
      rescue => e
        puts "Warning: Error sending prompt end event: #{e.message}"
      end
      
      # Close the stream safely
      if @stream
        puts "Attempting to close audio stream..."
        begin
          @stream.close 
          puts "Audio stream closed successfully"
        rescue => e
          puts "Warning: Error closing audio stream: #{e.message}"
        end
      end
      
      puts "Shutdown successful"
    rescue => e
      puts "Error during shutdown: #{e.message}"
    end
  end
end

# Main execution starts here
if __FILE__ == $0
  begin
    require 'io/console'
  rescue LoadError
    puts "Warning: io/console not available. Echo test key press detection may not work."
  end
  
  nova = NovaSonic.new
  
  # Set up signal handlers for clean shutdown
  force_exit_in_progress = false
  
  ['INT', 'TERM'].each do |signal|
    trap(signal) do
      # If we're already in the process of shutting down and receive another signal, force quit
      if force_exit_in_progress
        puts "\nReceived multiple interrupt signals. Forcing immediate exit!"
        Process.kill('KILL', Process.pid)
      end
      
      force_exit_in_progress = true
      puts "\nReceived #{signal} signal. Shutting down..."
      
      # Create a safety timer in case shutdown gets stuck
      Thread.new do
        sleep 2 # Wait 2 seconds for graceful shutdown
        puts "Forced exit due to timeout in signal handler"
        Process.kill('KILL', Process.pid)
      end
      
      begin
        nova.shutdown
      rescue => e
        puts "Error during shutdown: #{e.message}"
        Process.kill('KILL', Process.pid)
      end
    end
  end
  
  # Add QUIT handler for immediate termination (CTRL+\)
  trap('QUIT') do
    puts "\nReceived QUIT signal. Forcing immediate termination..."
    Process.kill('KILL', Process.pid)
  end
  
  Thread.abort_on_exception = true
  
  # Initialize with echo test
  puts "Starting with echo test to verify microphone is working..."
  nova.start_session
  nova.start_audio_input
  stream = nova.start_audio_stream
  nova.start_echo_test
  
  # Add a main loop that can be interrupted
  begin
    # Create a small loop that checks for running status periodically
    while nova.instance_variable_get(:@is_active)
      sleep 0.5
    end
  rescue => e
    puts "Error in main loop: #{e}"
  ensure
    # Clean up
    nova.shutdown
  end
end