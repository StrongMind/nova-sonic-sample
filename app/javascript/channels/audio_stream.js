import consumer from "./consumer"

let recorder = null;
let audioStream = null;
let subscription = null;
let reconnectAttempts = 0;
const MAX_RECONNECT_ATTEMPTS = 5;

// ---------------- Audio Player Implementation ----------------
// Implementation based on the approach in node-example/public/src/main.js
let audioContext = null;
let audioWorkletNode = null;
let audioInitialized = false;

// Base64 to Float32Array conversion (same as in main.js)
function base64ToFloat32Array(base64String) {
  try {
    const binaryString = window.atob(base64String);
    const bytes = new Uint8Array(binaryString.length);
    for (let i = 0; i < binaryString.length; i++) {
      bytes[i] = binaryString.charCodeAt(i);
    }

    const int16Array = new Int16Array(bytes.buffer);
    const float32Array = new Float32Array(int16Array.length);
    for (let i = 0; i < int16Array.length; i++) {
      float32Array[i] = int16Array[i] / 32768.0;
    }

    return float32Array;
  } catch (error) {
    console.error('Error in base64ToFloat32Array:', error);
    throw error;
  }
}

// Initialize audio context for playback
async function initAudioPlayer() {
  if (audioInitialized) return;
  
  try {
    // Check default system sample rate first
    const tempContext = new (window.AudioContext || window.webkitAudioContext)();
    const systemSampleRate = tempContext.sampleRate;
    tempContext.close();
    
    console.log(`System audio sample rate: ${systemSampleRate}Hz, Bedrock audio sample rate: 16000Hz`);
    
    // Always try to use 16000Hz to match Bedrock's output
    // On some browsers this may be overridden to the system rate
    audioContext = new (window.AudioContext || window.webkitAudioContext)({
      sampleRate: 16000 // Match Bedrock's output sample rate
    });
    
    console.log(`Actual audio context sample rate: ${audioContext.sampleRate}Hz`);
    
    // Create a simple gain node for volume control
    const gainNode = audioContext.createGain();
    gainNode.gain.value = 1.0; // Set volume to 100%
    gainNode.connect(audioContext.destination);
    
    audioInitialized = true;
    console.log("Audio player initialized successfully");
    return gainNode;
  } catch (error) {
    console.error("Failed to initialize audio player:", error);
    return null;
  }
}

// Play audio using the simple player
async function playAudio(float32AudioData) {
  if (!audioInitialized) {
    await initAudioPlayer();
  }
  
  if (!audioContext) {
    console.error("Audio context not available");
    return;
  }
  
  try {
    const bedrockSampleRate = 16000;
    const outputSampleRate = audioContext.sampleRate;
    
    // If the sample rates don't match, we need to resample
    if (bedrockSampleRate !== outputSampleRate) {
      console.warn(`Audio sample rate mismatch: Bedrock sample rate is ${bedrockSampleRate}Hz, but audio context sample rate is ${outputSampleRate}Hz`);
    }
    
    // Create an audio buffer with the audio data
    const audioBuffer = audioContext.createBuffer(1, float32AudioData.length, outputSampleRate);
    const channelData = audioBuffer.getChannelData(0);
    
    // Copy the float32 audio data to the buffer
    channelData.set(float32AudioData);
    
    // Create a buffer source
    const source = audioContext.createBufferSource();
    source.buffer = audioBuffer;
    
    // Connect to the audio context destination
    source.connect(audioContext.destination);
    
    // Start playing
    source.start();
    console.log("Audio playback started with sample rate:", outputSampleRate);
  } catch (error) {
    console.error("Error playing audio:", error);
  }
}

function connect() {
  if (subscription) {
    console.log("Cleaning up existing subscription");
    subscription.unsubscribe();
  }

  console.log("Attempting to connect with session ID:", window.sessionId);
  subscription = consumer.subscriptions.create(
    {
      channel: "AudioStreamChannel",
      session_id: window.sessionId
    },
    {
      connected() {
        console.log("Connected to AudioStreamChannel");
        reconnectAttempts = 0;
        updateConnectionStatus('Connected', true);
      },

      disconnected() {
        console.log("Disconnected from AudioStreamChannel");
        updateConnectionStatus('Disconnected', false);
        
        if (recorder && recorder.state === 'recording') {
          stopRecording();
        }

        // Handle reconnection
        if (reconnectAttempts < MAX_RECONNECT_ATTEMPTS) {
          reconnectAttempts++;
          console.log(`Reconnection attempt ${reconnectAttempts} of ${MAX_RECONNECT_ATTEMPTS}`);
          setTimeout(connect, 2000 * reconnectAttempts); // Exponential backoff
        } else {
          console.log("Max reconnection attempts reached");
          updateConnectionStatus('Connection failed - please refresh the page', false);
        }
      },

      rejected() {
        console.log("Subscription was rejected");
        updateConnectionStatus('Connection rejected', false);
      },

      received(data) {
        console.log("Received data:", data);
        
        // Handle subscription confirmation
        if (data.type === 'confirm_subscription') {
          console.log("Subscription confirmed with session ID:", data.sessionId);
          document.getElementById('startButton').disabled = false;
        }
        
        // Handle audio processing status
        else if (data.type === 'audio_processing') {
          console.log(`Processing ${data.size} bytes of audio data in ${data.format} format`);
        }
        
        // Handle chunk events from Bedrock
        else if (data.type === 'chunk') {
          console.log("Received chunk data:", data);
          
          // Extract text content from chunk if available
          if (data.data && data.data.event && data.data.event.textOutput) {
            const textContent = data.data.event.textOutput.content;
            if (textContent) {
              const chatHistory = document.getElementById('chatHistory');
              const messageDiv = document.createElement('div');
              messageDiv.className = 'message assistant';
              messageDiv.textContent = textContent;
              chatHistory.appendChild(messageDiv);
              chatHistory.scrollTop = chatHistory.scrollHeight;
            }
          }
        }
        
        // Handle text output from Bedrock model
        else if (data.type === 'textOutput') {
          console.log("Received text output:", data);
          
          // Handle both formats: direct content or nested event structure
          let content = '';
          if (data.data && data.data.event && data.data.event.textOutput) {
            content = data.data.event.textOutput.content;
          } else if (data.data && data.data.content) {
            content = data.data.content;
          } else if (data.data) {
            // If we can't find content in expected places, log the data and use stringified version
            console.warn("Unexpected textOutput structure:", data.data);
            content = JSON.stringify(data.data);
          }
          
          if (content) {
            const chatHistory = document.getElementById('chatHistory');
            const messageDiv = document.createElement('div');
            messageDiv.className = 'message assistant';
            messageDiv.textContent = content;
            chatHistory.appendChild(messageDiv);
            chatHistory.scrollTop = chatHistory.scrollHeight;
          }
        }
        
        // Handle audio output from Bedrock model
        else if (data.type === 'audioOutput') {
          console.log("Received audio output");
          
          // Get audio content, handling different possible structures
          let audioContent = '';
          if (data.data && data.data.event && data.data.event.audioOutput) {
            const audioOutput = data.data.event.audioOutput;
            audioContent = audioOutput.content;
            console.log("Audio configuration:", audioOutput.mediaType, 
                      audioOutput.sampleRateHertz, 
                      audioOutput.sampleSizeBits, 
                      audioOutput.channelCount);
          } else if (data.data && data.data.content) {
            audioContent = data.data.content;
          } else if (data.data) {
            console.warn("Unexpected audioOutput structure:", data.data);
            return; // Can't process audio without proper content
          }
          
          if (!audioContent) {
            console.error("No audio content found in output");
            return;
          }
          
          try {
            // Using the same approach as in main.js
            const audioData = base64ToFloat32Array(audioContent);
            playAudio(audioData);
            console.log("Audio playback started with sample count:", audioData.length);
          } catch (error) {
            console.error("Error processing audio:", error, error.stack);
          }
        }
        
        // Handle errors
        else if (data.type === 'error') {
          console.error("Received error:", data.message, data.details);
          
          const chatHistory = document.getElementById('chatHistory');
          const errorDiv = document.createElement('div');
          errorDiv.className = 'message error';
          errorDiv.textContent = `Error: ${data.message}`;
          if (data.details) {
            const detailsDiv = document.createElement('div');
            detailsDiv.className = 'error-details';
            detailsDiv.textContent = data.details;
            errorDiv.appendChild(detailsDiv);
          }
          chatHistory.appendChild(errorDiv);
          chatHistory.scrollTop = chatHistory.scrollHeight;
        }
        
        // Handle any other messages for display
        else if (data.message) {
          console.log("Received message:", data.message);
          appendMessage(data.message);
        }
      }
    }
  );
}

function updateConnectionStatus(message, isConnected) {
  const statusElement = document.getElementById('connectionStatus');
  statusElement.textContent = message;
  statusElement.classList.remove('connected', 'disconnected');
  statusElement.classList.add(isConnected ? 'connected' : 'disconnected');
  document.getElementById('startButton').disabled = !isConnected;
  document.getElementById('stopButton').disabled = true;
}

function appendMessage(message) {
  const chatHistory = document.getElementById('chatHistory');
  const messageDiv = document.createElement('div');
  messageDiv.textContent = message;
  chatHistory.appendChild(messageDiv);
  chatHistory.scrollTop = chatHistory.scrollHeight;
}

function startRecording() {
  if (!subscription) {
    console.error("No active subscription");
    return;
  }

  // Send audio_start event before starting recording
  subscription.send({
    type: 'audio_start',
    session_id: window.sessionId
  });

  navigator.mediaDevices.getUserMedia({ 
    audio: {
      sampleRate: 16000,
      channelCount: 1,
      echoCancellation: true,
      noiseSuppression: true,
      autoGainControl: true
    }
  })
    .then(stream => {
      audioStream = stream;
      
      // Create AudioContext for processing audio
      const audioContext = new (window.AudioContext || window.webkitAudioContext)({
        sampleRate: 16000
      });
      
      // Create audio source from stream
      const source = audioContext.createMediaStreamSource(stream);
      
      // Create processor to handle audio
      const processor = audioContext.createScriptProcessor(512, 1, 1);
      
      processor.onaudioprocess = (e) => {
        // Get raw audio data
        const inputData = e.inputBuffer.getChannelData(0);
        
        // Convert to 16-bit PCM
        const pcmData = new Int16Array(inputData.length);
        for (let i = 0; i < inputData.length; i++) {
          pcmData[i] = Math.max(-1, Math.min(1, inputData[i])) * 0x7FFF;
        }
        
        // Convert to base64 (browser-safe way)
        const base64Data = arrayBufferToBase64(pcmData.buffer);
        
        // Send to server
        if (subscription) {
          subscription.send({
            type: 'audio_input',
            audio_data: base64Data,
            session_id: window.sessionId
          });
        }
      };
      
      // Connect nodes
      source.connect(processor);
      processor.connect(audioContext.destination);
      
      // Store references
      recorder = {
        audioContext: audioContext,
        source: source,
        processor: processor,
        state: 'recording',
        stop: function() {
          this.state = 'inactive';
          source.disconnect();
          processor.disconnect();
        }
      };
      
      document.getElementById('startButton').disabled = true;
      document.getElementById('stopButton').disabled = false;
    })
    .catch(error => {
      console.error('Error accessing microphone:', error);
      alert('Error accessing microphone. Please ensure you have granted microphone permissions.');
    });
}

function arrayBufferToBase64(buffer) {
  const binary = [];
  const bytes = new Uint8Array(buffer);
  for (let i = 0; i < bytes.byteLength; i++) {
    binary.push(String.fromCharCode(bytes[i]));
  }
  return btoa(binary.join(''));
}

function stopRecording() {
  if (recorder && recorder.state === 'recording') {
    recorder.stop();
    
    if (audioStream) {
      audioStream.getTracks().forEach(track => track.stop());
    }
    
    if (subscription) {
      subscription.send({
        type: 'stop_audio',
        session_id: window.sessionId
      });
    }
    
    document.getElementById('startButton').disabled = false;
    document.getElementById('stopButton').disabled = true;
  }
}

// Function to create a WAV file from LPCM data
function createWavFromLPCM(lpcmData, sampleRate, bitsPerSample, numChannels) {
  // WAV header size
  const headerSize = 44;
  
  // Create a new ArrayBuffer for the WAV file (header + data)
  const wavBuffer = new ArrayBuffer(headerSize + lpcmData.length);
  const view = new DataView(wavBuffer);
  
  // Write WAV header
  // "RIFF" chunk descriptor
  view.setUint8(0, 0x52); // 'R'
  view.setUint8(1, 0x49); // 'I'
  view.setUint8(2, 0x46); // 'F' 
  view.setUint8(3, 0x46); // 'F'
  
  // Chunk size: 4 (WAVE) + 24 (fmt ) + 8 (data header) + data length
  view.setUint32(4, 36 + lpcmData.length, true);
  
  // "WAVE" format
  view.setUint8(8, 0x57);  // 'W'
  view.setUint8(9, 0x41);  // 'A'
  view.setUint8(10, 0x56); // 'V'
  view.setUint8(11, 0x45); // 'E'
  
  // "fmt " sub-chunk
  view.setUint8(12, 0x66); // 'f'
  view.setUint8(13, 0x6D); // 'm'
  view.setUint8(14, 0x74); // 't'
  view.setUint8(15, 0x20); // ' '
  
  // Sub-chunk size (16 for PCM)
  view.setUint32(16, 16, true);
  
  // Audio format (1 = PCM)
  view.setUint16(20, 1, true);
  
  // Number of channels
  view.setUint16(22, numChannels, true);
  
  // Sample rate
  view.setUint32(24, sampleRate, true);
  
  // Byte rate: SampleRate * NumChannels * BitsPerSample/8
  view.setUint32(28, sampleRate * numChannels * (bitsPerSample / 8), true);
  
  // Block align: NumChannels * BitsPerSample/8
  view.setUint16(32, numChannels * (bitsPerSample / 8), true);
  
  // Bits per sample
  view.setUint16(34, bitsPerSample, true);
  
  // "data" sub-chunk
  view.setUint8(36, 0x64); // 'd'
  view.setUint8(37, 0x61); // 'a'
  view.setUint8(38, 0x74); // 't'
  view.setUint8(39, 0x61); // 'a'
  
  // Data size (raw audio data size)
  view.setUint32(40, lpcmData.length, true);
  
  // Copy audio data
  const wavBytes = new Uint8Array(wavBuffer);
  wavBytes.set(lpcmData, headerSize);
  
  // Additional check for 16-bit PCM
  if (bitsPerSample === 16) {
    // We may need to swap bytes for endianness if the audio is garbled
    // If your audio sounds garbled, try uncommenting this code
    
    const dataView = new DataView(wavBuffer);
    for (let i = 0; i < lpcmData.length / 2; i++) {
      const offset = headerSize + i * 2;
      const value = dataView.getInt16(offset, true); // Read as little endian
      dataView.setInt16(offset, value, false); // Write as big endian
    }
    
  }
  
  return wavBytes;
}

// Set up event listeners when the DOM is loaded
document.addEventListener('DOMContentLoaded', () => {
  const startButton = document.getElementById('startButton');
  const stopButton = document.getElementById('stopButton');

  startButton.addEventListener('click', startRecording);
  stopButton.addEventListener('click', stopRecording);

  // Initialize connection
  connect();
}); 