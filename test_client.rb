#!/usr/bin/env ruby

require_relative 'app/services/nova_sonic_bidirectional_stream_client'
require 'logger'
require 'dotenv'
require 'base64'
require 'optparse'

# Load environment variables from .env file if present
if defined?(Dotenv)
  puts "Loading environment from .env file"
  Dotenv.load
else
  puts "Dotenv not available, skipping .env loading"
end

# Parse command line options
options = {
  input_file: nil,
  sample_rate: 16000
}

OptionParser.new do |opts|
  opts.banner = "Usage: #{$0} [options]"

  opts.on("-i", "--input FILE", "Input audio file (raw PCM 16-bit, 16kHz, mono)") do |f|
    options[:input_file] = f
  end
  
  opts.on("-r", "--rate RATE", Integer, "Sample rate of input file (default: 16000)") do |r|
    options[:sample_rate] = r
  end
  
  opts.on("-h", "--help", "Show this help message") do
    puts opts
    exit
  end
end.parse!

# Set up logger
logger = Logger.new(STDOUT)
logger.level = Logger::INFO

# Get and validate AWS credentials
aws_access_key = ENV['AWS_ACCESS_KEY_ID']
aws_secret_key = ENV['AWS_SECRET_ACCESS_KEY']
aws_session_token = ENV['AWS_SESSION_TOKEN']

puts "AWS credentials check:"
puts "  Access key available: #{!aws_access_key.nil? && !aws_access_key.empty?}"
puts "  Secret key available: #{!aws_secret_key.nil? && !aws_secret_key.empty?}"
puts "  Session token available: #{!aws_session_token.nil? && !aws_session_token.empty?}"

credentials = {
  access_key_id: aws_access_key,
  secret_access_key: aws_secret_key
}

# Add session token if available
credentials[:session_token] = aws_session_token if !aws_session_token.nil? && !aws_session_token.empty?

if credentials[:access_key_id].nil? || credentials[:access_key_id].empty? || 
   credentials[:secret_access_key].nil? || credentials[:secret_access_key].empty?
  puts "ERROR: AWS credentials not properly set"
  puts "Please set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables"
  exit 1
else
  puts "AWS credentials look valid"
end

def create_test_audio_file
  # Create a simple audio file with a sine wave (16kHz, 16-bit PCM, 1 channel, 1 second)
  puts "Creating test audio file..."
  
  # Parameters
  sample_rate = 16000
  duration_seconds = 1
  frequency = 440 # A4 note
  
  # Generate a sine wave
  samples = (0...sample_rate * duration_seconds).map do |i|
    amplitude = 0.5 * 32767 # Half of max 16-bit amplitude
    (amplitude * Math.sin(2 * Math::PI * frequency * i / sample_rate)).to_i
  end
  
  # Convert to 16-bit PCM
  audio_data = samples.pack("s*") # 's' is for signed 16-bit integer
  
  # Save to file
  File.open("test_audio.raw", "wb") do |file|
    file.write(audio_data)
  end
  
  puts "Created test audio file (#{audio_data.size} bytes)"
  audio_data
end

# Function to write a WAV header
def write_wav_header(file, data_size, channels=1, bits_per_sample=16, sample_rate=16000)
  chunk_size = 36 + data_size
  byte_rate = sample_rate * channels * bits_per_sample / 8
  block_align = channels * bits_per_sample / 8

  # Write the RIFF chunk descriptor
  file.write("RIFF")                       # ChunkID (4 bytes)
  file.write([chunk_size].pack('V'))       # ChunkSize (4 bytes)
  file.write("WAVE")                       # Format (4 bytes)
  
  # Write the fmt sub-chunk
  file.write("fmt ")                       # Subchunk1ID (4 bytes)
  file.write([16].pack('V'))               # Subchunk1Size (4 bytes) - 16 for PCM
  file.write([1].pack('v'))                # AudioFormat (2 bytes) - 1 for PCM
  file.write([channels].pack('v'))         # NumChannels (2 bytes)
  file.write([sample_rate].pack('V'))      # SampleRate (4 bytes)
  file.write([byte_rate].pack('V'))        # ByteRate (4 bytes)
  file.write([block_align].pack('v'))      # BlockAlign (2 bytes)
  file.write([bits_per_sample].pack('v'))  # BitsPerSample (2 bytes)
  
  # Write the data sub-chunk
  file.write("data")                       # Subchunk2ID (4 bytes)
  file.write([data_size].pack('V'))        # Subchunk2Size (4 bytes)
end

def raw_to_wav(raw_data, output_file, sample_rate=16000, channels=1, bits_per_sample=16)
  puts "Converting raw audio (#{raw_data.size} bytes) to WAV format..."
  
  begin
    File.open(output_file, 'wb') do |file|
      write_wav_header(file, raw_data.size, channels, bits_per_sample, sample_rate)
      file.write(raw_data)
    end
    puts "Successfully created WAV file: #{output_file} (#{channels} channel(s), #{bits_per_sample} bits, #{sample_rate} Hz)"
  rescue => e
    puts "Error creating WAV file: #{e.message}"
    puts e.backtrace.join("\n")
  end
end

begin
  puts "=============================================="
  puts "Initializing Nova Sonic client..."
  client = NovaSonicBidirectionalStreamClient.new(
    region: 'us-east-1',
    credentials: credentials
  )
  puts "Client initialized successfully"

  # Create a session
  puts "=============================================="
  puts "Creating a stream session..."
  session = client.create_stream_session
  puts "Created session with ID: #{session.session_id}"

  # Set up event handlers
  puts "=============================================="
  puts "Setting up event handlers..."
  
  # Keep track of audio chunks
  audio_chunks = []
  timestamp = Time.now.to_i
  output_base = "output_#{timestamp}"
  
  session.on_event('textOutput') do |data|
    puts "----------------------------------------"
    puts "Text output: #{data['content']}"
    puts "----------------------------------------"
  end

  session.on_event('audioOutput') do |data|
    puts "----------------------------------------"
    puts "Received audio output (#{data['content'].length} bytes)"
    
    # Decode and store audio chunk
    decoded_chunk = Base64.decode64(data['content'])
    audio_chunks << decoded_chunk
    
    # Save raw output
    raw_filename = "#{output_base}_part_#{audio_chunks.size}.raw"
    puts "Writing audio data to #{raw_filename}"
    File.open(raw_filename, "wb") do |file|
      file.write(decoded_chunk)
    end
    puts "----------------------------------------"
  end

  session.on_event('error') do |data|
    puts "----------------------------------------"
    puts "ERROR EVENT: #{data.inspect}"
    puts "----------------------------------------"
  end

  session.on_event('contentStart') do |data|
    puts "----------------------------------------"
    puts "Content start: #{data.inspect}"
    puts "----------------------------------------"
  end

  session.on_event('contentEnd') do |data|
    puts "----------------------------------------"
    puts "Content end: #{data.inspect}"
    puts "----------------------------------------"
  end

  session.on_event('any') do |data|
    puts "----------------------------------------"
    puts "Generic event (#{data[:type]}): #{data[:data].inspect}"
    puts "----------------------------------------"
  end

  # Initialize the session
  puts "=============================================="
  puts "Initiating the session..."
  
  # Start the session in a separate thread to avoid blocking
  thread = Thread.new do
    begin
      puts "Session thread started"
      client.initiate_session(session.session_id)
      puts "Session thread completed normally"
    rescue => e
      puts "ERROR IN SESSION THREAD:"
      puts e.message
      puts e.backtrace.join("\n")
    end
  end

  # Set up initial events
  puts "=============================================="
  puts "Setting up prompt..."
  client.setup_prompt_start_event(session.session_id)
  puts "Prompt start event sent"
  
  client.setup_system_prompt_event(session.session_id)
  puts "System prompt event sent"
  
  client.setup_start_audio_event(session.session_id)
  puts "Audio start event sent"

  # Wait for 2 seconds to allow initialization
  puts "=============================================="
  puts "Waiting for initialization (2 seconds)..."
  sleep(2)

  # Additional wait time to ensure the session is fully established
  puts "=============================================="
  puts "Waiting for session to fully establish (5 seconds)..."
  sleep(5)

  # Get audio data - either from file or generate test data
  puts "=============================================="
  puts "Preparing audio data..."
  
  if options[:input_file] && File.exist?(options[:input_file])
    puts "Reading audio data from #{options[:input_file]}"
    audio_data = File.binread(options[:input_file])
    puts "Read #{audio_data.length} bytes of audio data"
  else
    puts "No input file specified or file not found. Using generated test audio..."
    audio_data = create_test_audio_file
    puts "Generated #{audio_data.length} bytes of test audio data"
  end

  # Stream the audio
  puts "=============================================="
  puts "Streaming audio data..."

  # Break audio data into smaller chunks to reduce server load
  chunk_size = 8000 # 8KB chunks (small enough to avoid overwhelming the server)
  total_chunks = (audio_data.length / chunk_size.to_f).ceil

  puts "Breaking audio into #{total_chunks} smaller chunks"
  max_retries = 3
  retry_count = 0

  begin
    # Stream in smaller chunks with small delays between them
    (0...total_chunks).each do |chunk_index|
      start_pos = chunk_index * chunk_size
      end_pos = [start_pos + chunk_size, audio_data.length].min
      chunk = audio_data[start_pos...end_pos]
      
      puts "Streaming chunk #{chunk_index + 1}/#{total_chunks} (#{chunk.length} bytes)"
      session.stream_audio(chunk)
      
      # Small delay between chunks to avoid overwhelming the server
      sleep(0.1) if chunk_index < total_chunks - 1
    end
    puts "Audio streaming completed"
  rescue => e
    puts "Error during audio streaming: #{e.message}"
    retry_count += 1
    if retry_count <= max_retries
      puts "Retrying audio streaming (attempt #{retry_count}/#{max_retries})..."
      sleep(2) # Wait a bit before retrying
      retry
    else
      puts "Max retries reached, continuing with the process"
    end
  end

  puts "Audio streaming initiated"

  # Wait for 5 seconds to allow processing
  puts "=============================================="
  puts "Waiting for processing (5 seconds)..."
  sleep(5)

  # End the audio content
  puts "=============================================="
  puts "Ending audio content..."
  session.end_audio_content
  puts "Audio content ended"

  # Wait for 2 seconds to allow final processing
  puts "=============================================="
  puts "Waiting for final processing (2 seconds)..."
  sleep(2)

  # End the prompt
  puts "=============================================="
  puts "Ending prompt..."
  session.end_prompt
  puts "Prompt ended"

  # Wait for 2 seconds
  puts "=============================================="
  puts "Waiting for 2 more seconds..."
  sleep(2)

  # Close the session
  puts "=============================================="
  puts "Closing the session..."
  session.close
  puts "Session close requested"

  # Wait for the thread to finish (with timeout)
  puts "=============================================="
  puts "Waiting for thread to complete..."
  thread.join(10) # Wait up to 10 seconds

  if thread.alive?
    puts "Thread is still running - this may indicate a problem"
    puts "Forcefully exiting"
  else
    puts "Thread completed successfully"
  end

  # Combine and convert audio chunks to WAV
  unless audio_chunks.empty?
    puts "=============================================="
    puts "Creating WAV file from received audio..."
    
    # Combine all audio chunks
    combined_audio = audio_chunks.join
    
    # Create raw file with all chunks
    raw_output = "#{output_base}_combined.raw"
    File.open(raw_output, "wb") { |f| f.write(combined_audio) }
    puts "Saved combined raw audio to #{raw_output} (#{combined_audio.length} bytes)"
    
    # Create WAV file with Nova Sonic parameters (24kHz, 16-bit, mono)
    wav_output = "#{output_base}.wav"
    raw_to_wav(combined_audio, wav_output, 24000, 1, 16)
    
    # Create a copy at 16kHz for compatibility with more players
    wav_output_16k = "#{output_base}_16k.wav"
    raw_to_wav(combined_audio, wav_output_16k, 16000, 1, 16)
    
    puts "Audio output files created:"
    puts "  - Raw PCM (24kHz): #{raw_output}"
    puts "  - WAV (24kHz): #{wav_output}" 
    puts "  - WAV (16kHz): #{wav_output_16k}"
    puts ""
    puts "You can play these files with:"
    puts "  - Any standard audio player (VLC, QuickTime, etc.)"
    puts "  - Command line: `afplay #{wav_output}` (macOS)"
    puts "  - Command line: `aplay #{wav_output}` (Linux)" 
  end

  puts "=============================================="
  puts "Test completed successfully"
rescue => e
  puts "=============================================="
  puts "CRITICAL ERROR:"
  puts e.message
  puts e.backtrace.join("\n")
end 