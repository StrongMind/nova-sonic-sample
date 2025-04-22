require 'aws-sdk-bedrockruntime'

# Create output file for audio data
output_file = File.open('output_audio.raw', 'wb')

async_client = Aws::BedrockRuntime::AsyncClient.new(region: 'us-east-1', enable_alpn: true) 
input_stream = Aws::BedrockRuntime::EventStreams::InvokeModelWithBidirectionalStreamInput.new
output_stream = Aws::BedrockRuntime::EventStreams::InvokeModelWithBidirectionalStreamOutput.new

output_stream.on_event do |e|
  puts "Output stream got an event: #{e}"
  if e[:event_type] == :chunk
    begin
      # Parse the JSON response
      response = JSON.parse(e[:bytes])
      if response['event'] && response['event']['audioOutput']
        # Decode base64 audio content and write to file
        audio_data = Base64.strict_decode64(response['event']['audioOutput']['content'])
        output_file.write(audio_data)
      end
    rescue JSON::ParserError => e
      puts "Failed to parse JSON: #{e}"
    end
  end
end
Thread.abort_on_exception = true
async_resp = async_client.invoke_model_with_bidirectional_stream(
  model_id: 'amazon.nova-sonic-v1:0',
  input_event_stream_handler: input_stream,
  output_event_stream_handler: output_stream
)

prompt_id = SecureRandom.uuid
content_id = SecureRandom.uuid
audio_content_id = SecureRandom.uuid
PREAMBLE = [
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
        "contentName": content_id,
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
        "contentName": content_id,
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
        "contentName": content_id
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

AUDIO_EVENT =
  {
    "event": {
      "audioInput": {
        "promptName": prompt_id,
        "contentName": audio_content_id,
        "content": "%s",
        "role": "USER"
      }
    }
  }.to_json

AUDIO_FILE = "./japan16k.raw"

request_events = PREAMBLE
File.open(AUDIO_FILE, 'rb') do |f|
  while (chunk = f.read(1024))
    request_events << AUDIO_EVENT % Base64.strict_encode64(chunk)
  end
end

request_events.each do |event|
  input_stream.signal_chunk_event(bytes: event)
end

async_resp.wait

# Close the output file
output_file.close