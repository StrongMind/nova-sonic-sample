#!/usr/bin/env ruby

require 'easy_audio'
require 'io/console'
require 'optparse'
require 'time'

class AudioEcho
  # Configuration
  SAMPLE_RATE = 16000
  CHANNELS = 1
  BITS_PER_SAMPLE = 16
  DEFAULT_RECORD_SECONDS = 5
  DEFAULT_OUTPUT_FILE = "recorded_audio_%s.raw"

  def initialize(options = {})
    @record_seconds = options[:duration] || DEFAULT_RECORD_SECONDS
    @auto_record = options[:auto_record] || false
    @current_timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
    @output_file = options[:output_file] || DEFAULT_OUTPUT_FILE % @current_timestamp
    @recording = []
    @playback_mode = false
    @start_time = nil
    @is_active = true
    @last_saved_file = nil
  end

  def start
    puts "Audio Echo - Press 'r' to start recording for #{@record_seconds} seconds"
    puts "Press 'p' to play the last saved recording from file"
    puts "Press 's' to save the last recording to a file (#{@output_file})"
    puts "Press 'q' to quit"

    # Start a thread to listen for key presses
    key_thread = Thread.new do
      while @is_active
        key = STDIN.getch rescue nil
        if key == 'r'
          start_recording
        elsif key == 'p'
          play_from_file
        elsif key == 's'
          save_to_file
        elsif key == 'q'
          @is_active = false
          puts "\nExiting..."
        end
      end
    end

    # Configure audio stream
    begin
      stream_options = {
        in: true,             # Enable microphone input
        out: true,            # Enable speaker output
        in_sample_rate: SAMPLE_RATE,
        out_sample_rate: SAMPLE_RATE,
        in_channels: CHANNELS,
        out_channels: CHANNELS,
        latency: 0.1,         # Low latency
        on_error: ->(err) { puts "Audio error: #{err}"; @is_active = false }
      }
      
      puts "Starting audio stream..."
      @stream = EasyAudio.easy_open(stream_options) do |input_sample|
        # Exit the block if we're no longer running
        next 0.0 unless @is_active
        
        # Input handling (when we receive a sample from the microphone)
        if input_sample && @start_time && !@playback_mode
          # Store the sample in our recording buffer
          @recording << input_sample
        
          # Periodically print buffer size for debugging
          if @recording.size % 8000 == 0
            puts "Recording buffer size: #{@recording.size} samples (#{@recording.size.to_f / SAMPLE_RATE} seconds)"
          end
          
          # Check if recording time has elapsed
          if Time.now - @start_time >= @record_seconds
            stop_recording
          end
        end
        
        # Output handling (returning the next sample to play)
        if @playback_mode && !@recording.empty?
          # Print playback progress periodically
          if @recording.size % 8000 == 0
            puts "Playback progress: #{@recording_backup.size - @recording.size} of #{@recording_backup.size} samples played"
          end
          # Return the next sample from our recording
          @recording.shift
        else
          # Return silence
          0.0
        end
      end
      
      # If auto-record is enabled, start recording immediately
      start_recording if @auto_record
      
      # Keep the main thread alive
      while @is_active
        sleep 0.1
      end
      
      # Clean up
      @stream.close if @stream
      key_thread.exit if key_thread.alive?
      
    rescue => e
      puts "Error: #{e.message}"
      puts e.backtrace.join("\n")
      @is_active = false
    end
  end

  def start_recording
    puts "Recording started... (#{@record_seconds} seconds)"
    @recording = []
    @playback_mode = false
    @start_time = Time.now
    
    # Update timestamp and output filename
    @current_timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
    @output_file = DEFAULT_OUTPUT_FILE % @current_timestamp unless @output_file != DEFAULT_OUTPUT_FILE % @current_timestamp
  end

  def stop_recording
    return if @recording.empty?
    
    @playback_mode = true
    puts "Recording stopped. #{@recording.size} samples recorded (#{@recording.size.to_f / SAMPLE_RATE} seconds)"
    puts "Playing back..."
    
    # Save a copy of the recording since we'll consume it during playback
    @recording_backup = @recording.dup
    
    # Wait for playback to complete
    Thread.new do
      # Estimate the duration based on sample rate
      playback_duration = @recording.size.to_f / SAMPLE_RATE
      sleep playback_duration + 0.5 # Add a small buffer
      puts "Playback complete."
      puts "Press 'r' to record again, 's' to save to file, or 'q' to quit"
      
      # Restore the recording in case user wants to play it again
      @recording = @recording_backup.dup
      @playback_mode = false
    end
  end
  
  def save_to_file
    if @recording_backup.nil? || @recording_backup.empty?
      puts "No recording to save!"
      return
    end
    
    # Convert float samples (-1.0 to 1.0) to 16-bit PCM
    begin
      File.open(@output_file, 'wb') do |file|
        pcm_data = @recording_backup.map { |sample| (sample * 32767).to_i }.pack('s*')
        file.write(pcm_data)
      end
      puts "Recording saved to #{@output_file} (#{@recording_backup.size} samples, #{@recording_backup.size.to_f / SAMPLE_RATE} seconds)"
      @last_saved_file = @output_file
    rescue => e
      puts "Error saving file: #{e.message}"
    end
  end
  
  def play_from_file
    file_to_play = @last_saved_file || @output_file
    
    if !File.exist?(file_to_play)
      puts "File not found: #{file_to_play}"
      # Try to list any *.raw files that might exist
      raw_files = Dir.glob("*.raw")
      if raw_files.any?
        puts "Available .raw files:"
        raw_files.each { |f| puts "  - #{f}" }
        puts "Press 'p' again after saving a recording first."
      end
      return
    end
    
    begin
      # Load the file into the playback buffer
      @playback_mode = true
      @recording = []
      
      # Read the raw PCM data and convert back to float samples
      pcm_data = File.binread(file_to_play)
      int16_samples = pcm_data.unpack('s*')
      float_samples = int16_samples.map { |sample| sample / 32768.0 }
      @recording = float_samples
      
      # Make a backup copy
      @recording_backup = @recording.dup
      
      puts "Playing audio from #{file_to_play} (#{@recording.size} samples, #{@recording.size.to_f / SAMPLE_RATE} seconds)"
      
      # Wait for playback to complete
      Thread.new do
        # Estimate the duration based on sample rate
        playback_duration = @recording.size.to_f / SAMPLE_RATE
        sleep playback_duration + 0.5 # Add a small buffer
        puts "Playback complete."
        
        # Restore the recording in case user wants to play it again
        @recording = @recording_backup.dup
        @playback_mode = false
      end
    rescue => e
      puts "Error playing file: #{e.message}"
      puts e.backtrace.join("\n")
      @playback_mode = false
    end
  end
  
  def self.list_audio_devices
    puts "Available audio devices:"
    begin
      EasyAudio.list_devices.each_with_index do |dev, i|
        puts "#{i}: #{dev['name']} (#{dev['input'] ? 'Input' : ''}#{dev['input'] && dev['output'] ? '/' : ''}#{dev['output'] ? 'Output' : ''})"
      end
    rescue => e
      puts "Error listing devices: #{e.message}"
      puts e.backtrace.join("\n")
    end
  end
end

# Parse command line options
if __FILE__ == $0
  options = {}
  
  opt_parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby echo.rb [options]"
    
    opts.on("-d", "--duration SECONDS", Integer, "Recording duration in seconds (default: 5)") do |d|
      options[:duration] = d
    end
    
    opts.on("-a", "--auto-record", "Start recording automatically") do
      options[:auto_record] = true
    end
    
    opts.on("-o", "--output FILENAME", "Specify output filename (default: recorded_audio_TIMESTAMP.raw)") do |f|
      options[:output_file] = f
    end
    
    opts.on("-l", "--list-devices", "List available audio devices") do
      AudioEcho.list_audio_devices
      exit
    end
    
    opts.on("-h", "--help", "Show this help message") do
      puts opts
      exit
    end
    
    opts.on("-v", "--verbose", "Enable verbose output") do
      $verbose = true
    end
  end
  
  begin
    opt_parser.parse!
    echo = AudioEcho.new(options)
    echo.start
  rescue OptionParser::InvalidOption, OptionParser::MissingArgument => e
    puts e.message
    puts opt_parser
    exit 1
  rescue => e
    puts "Unexpected error: #{e.message}"
    puts e.backtrace.join("\n")
    exit 1
  end
end
