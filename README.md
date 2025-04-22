# Nova Sonic Ruby Client

This repository contains a Ruby implementation of a client for Amazon's Nova Sonic service, which provides speech-to-speech capabilities via AWS Bedrock.

## Requirements

- Ruby 2.7+
- AWS credentials with access to the Bedrock service
- Rails 6.0+ (for ActionCable features)

## Installation

Add the following to your Gemfile:

```ruby
gem 'aws-sdk-bedrockruntime'
gem 'concurrent-ruby'
```

Then run:

```bash
bundle install
```

## Usage

### Basic Usage

```ruby
require_relative 'app/services/nova_sonic_bidirectional_stream_client'

# Initialize the client
client = NovaSonicBidirectionalStreamClient.new(
  region: 'us-east-1',
  credentials: {
    access_key_id: ENV['AWS_ACCESS_KEY_ID'],
    secret_access_key: ENV['AWS_SECRET_ACCESS_KEY']
  }
)

# Create a new session
session = client.create_stream_session

# Set up event handlers
session.on_event('textOutput') do |data|
  puts "Text output: #{data}"
end

session.on_event('audioOutput') do |data|
  # Save base64 audio data or play it
  File.open("output.wav", "wb") do |file|
    file.write(data)
  end
end

session.on_event('error') do |data|
  puts "Error: #{data}"
end

# Initialize the session with AWS
client.initiate_session(session.session_id)

# Set up initial events
client.setup_prompt_start_event(session.session_id)
client.setup_system_prompt_event(session.session_id)
client.setup_start_audio_event(session.session_id)

# Stream audio data
audio_data = File.read("input.wav")
session.stream_audio(audio_data)

# End the audio content when done streaming
session.end_audio_content

# Close the session when completely done
session.close
```

### Integration with Rails ActionCable

The client can be easily integrated with Rails ActionCable to create a websocket-based voice interface:

1. Create an ActionCable channel (see `app/channels/audio_stream_channel.rb`)
2. Initialize the Nova Sonic client when a user subscribes
3. Set up event handlers that transmit data back to the client
4. Process audio data received from the client and send it to Nova Sonic

## AWS Bedrock Configuration

Make sure you have:

1. Set up your AWS credentials
2. Enabled the Amazon Nova Sonic model in your AWS Bedrock console
3. Assigned proper IAM permissions for accessing Bedrock services

## Features

- Real-time bidirectional streaming
- Audio input/output handling
- System prompt customization
- Tool usage support (weather, date/time)
- Multiple concurrent sessions support
- Automatic session cleanup

## Development

### Running Tests

```bash
rails test test/services/nova_sonic_bidirectional_stream_client_test.rb
```

## License

This library is licensed under the MIT License.

# Nova Sonic Speech-to-Speech Test Client

This script allows you to test the Nova Sonic speech-to-speech bidirectional streaming API. You can use either a generated test tone or provide your own audio recording as input.

## Prerequisites

1. Valid AWS credentials with access to Nova Sonic
2. Ruby 2.6 or higher
3. Required Ruby gems: `aws-sdk-core`, `websocket-client-simple`, `dotenv`

## Setup

1. Make sure your AWS credentials are set:
   ```bash
   export AWS_ACCESS_KEY_ID=your_access_key
   export AWS_SECRET_ACCESS_KEY=your_secret_key
   ```
   
   Or create a `.env` file in this directory with:
   ```
   AWS_ACCESS_KEY_ID=your_access_key
   AWS_SECRET_ACCESS_KEY=your_secret_key
   ```

2. Install required gems:
   ```bash
   gem install aws-sdk-core websocket-client-simple dotenv
   ```

## Usage

### Using a generated test tone

```bash
ruby test_client.rb
```

This will generate a 1-second test tone (440Hz A4 note) and use it as input.

### Using your own recording

```bash
ruby test_client.rb -i your_audio_file.raw
```

**Important**: Your input audio file must be in raw PCM format (16-bit, mono, 16kHz by default). If your audio has a different sample rate, you can specify it:

```bash
ruby test_client.rb -i your_audio_file.raw -r 44100
```

### Converting audio files to the required format

If you have audio files in other formats (MP3, WAV, etc.), you can convert them to the required format using a tool like FFmpeg:

```bash
# Convert MP3 to raw PCM (16-bit, 16kHz, mono)
ffmpeg -i input.mp3 -ar 16000 -ac 1 -f s16le -acodec pcm_s16le output.raw

# Convert WAV to raw PCM (16-bit, 16kHz, mono)
ffmpeg -i input.wav -ar 16000 -ac 1 -f s16le -acodec pcm_s16le output.raw
```

## Output

The script produces several files:

1. `output_[timestamp]_part_[number].raw` - Individual raw PCM audio chunks as they arrive from the API
2. `output_[timestamp]_combined.raw` - All audio chunks combined into a single raw PCM file
3. `output_[timestamp].wav` - The combined audio converted to WAV format (playable in most audio players)

The WAV file can be opened and played in any standard audio player or editor (VLC, Audacity, etc.).

## Troubleshooting

- If you encounter authentication issues, check your AWS credentials
- Make sure your AWS user has the necessary permissions to access Nova Sonic
- If you have a large audio file, try splitting it into smaller segments
