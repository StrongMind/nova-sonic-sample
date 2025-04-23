import consumer from "./consumer"

let recorder = null;
let audioStream = null;
let subscription = null;
let reconnectAttempts = 0;
const MAX_RECONNECT_ATTEMPTS = 5;

// Track processed messages to prevent duplicates
let processedTextMessages = new Set();
let processedAudioMessages = new Set();

// ---------------- Audio Player Implementation ----------------
// Using the AudioPlayer class from the node-example
let audioPlayer = null;

// Base64 to Float32Array conversion
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

    console.log(`Converted base64 to Float32Array, length: ${float32Array.length}, sample values: ${float32Array.slice(0, 5)}`);
    return float32Array;
  } catch (error) {
    console.error('Error in base64ToFloat32Array:', error);
    throw error;
  }
}

// Import the AudioPlayer and ObjectExt classes
class ObjectExt {
  static exists(obj) {
    return obj !== undefined && obj !== null;
  }
}

// ExpandableBuffer implementation for AudioPlayerProcessor worklet
const audioPlayerProcessorCode = `
// Audio sample buffer to minimize reallocations
class ExpandableBuffer {
  constructor() {
    // Start with one second's worth of buffered audio capacity before needing to expand
    this.buffer = new Float32Array(24000);
    this.readIndex = 0;
    this.writeIndex = 0;
    this.underflowedSamples = 0;
    this.isInitialBuffering = true;
    this.initialBufferLength = 24000;  // One second
    this.lastWriteTime = 0;
  }

  logTimeElapsedSinceLastWrite() {
    const now = Date.now();
    if (this.lastWriteTime !== 0) {
      const elapsed = now - this.lastWriteTime;
      console.log(\`Elapsed time since last audio buffer write: \${elapsed} ms\`);
    }
    this.lastWriteTime = now;
  }

  write(samples) {
    this.logTimeElapsedSinceLastWrite();
    if (this.writeIndex + samples.length <= this.buffer.length) {
      // Enough space to append the new samples
    }
    else {
      // Not enough space ...
      if (samples.length <= this.readIndex) {
        // ... but we can shift samples to the beginning of the buffer
        const subarray = this.buffer.subarray(this.readIndex, this.writeIndex);
        console.log(\`Shifting the audio buffer of length \${subarray.length} by \${this.readIndex}\`);
        this.buffer.set(subarray);
      }
      else {
        // ... and we need to grow the buffer capacity to make room for more audio
        const newLength = (samples.length + this.writeIndex - this.readIndex) * 2;
        const newBuffer = new Float32Array(newLength);
        console.log(\`Expanding the audio buffer from \${this.buffer.length} to \${newLength}\`);
        newBuffer.set(this.buffer.subarray(this.readIndex, this.writeIndex));
        this.buffer = newBuffer;
      }
      this.writeIndex -= this.readIndex;
      this.readIndex = 0;
    }
    this.buffer.set(samples, this.writeIndex);
    this.writeIndex += samples.length;
    if (this.writeIndex - this.readIndex >= this.initialBufferLength) {
      // Filled the initial buffer length, so we can start playback with some cushion
      this.isInitialBuffering = false;
      console.log("Initial audio buffer filled");
    }
  }

  read(destination) {
    let copyLength = 0;
    if (!this.isInitialBuffering) {
      // Only start to play audio after we've built up some initial cushion
      copyLength = Math.min(destination.length, this.writeIndex - this.readIndex);
    }
    destination.set(this.buffer.subarray(this.readIndex, this.readIndex + copyLength));
    this.readIndex += copyLength;
    if (copyLength > 0 && this.underflowedSamples > 0) {
      console.log(\`Detected audio buffer underflow of \${this.underflowedSamples} samples\`);
      this.underflowedSamples = 0;
    }
    if (copyLength < destination.length) {
      // Not enough samples (buffer underflow). Fill the rest with silence.
      destination.fill(0, copyLength);
      this.underflowedSamples += destination.length - copyLength;
    }
    if (copyLength === 0) {
      // Ran out of audio, so refill the buffer to the initial length before playing more
      this.isInitialBuffering = true;
    }
  }

  clearBuffer() {
    this.readIndex = 0;
    this.writeIndex = 0;
  }
}

class AudioPlayerProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.playbackBuffer = new ExpandableBuffer();
    this.port.onmessage = (event) => {
      if (event.data.type === "audio") {
        this.playbackBuffer.write(event.data.audioData);
      }
      else if (event.data.type === "initial-buffer-length") {
        // Override the current playback initial buffer length
        const newLength = event.data.bufferLength;
        this.playbackBuffer.initialBufferLength = newLength;
        console.log(\`Changed initial audio buffer length to: \${newLength}\`)
      }
      else if (event.data.type === "barge-in") {
        this.playbackBuffer.clearBuffer();
      }
    };
  }

  process(inputs, outputs, parameters) {
    const output = outputs[0][0]; // Assume one output with one channel
    this.playbackBuffer.read(output);
    return true; // True to continue processing
  }
}

registerProcessor("audio-player-processor", AudioPlayerProcessor);
`;

// Audio recorder worklet processor code
const audioRecorderProcessorCode = `
class AudioRecorderProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.isRecording = false;
    
    this.port.onmessage = (event) => {
      if (event.data.type === "start-recording") {
        this.isRecording = true;
      } else if (event.data.type === "stop-recording") {
        this.isRecording = false;
      }
    };
  }

  process(inputs, outputs, parameters) {
    // If we're not recording or there's no input, just return
    if (!this.isRecording || !inputs[0] || !inputs[0][0] || inputs[0][0].length === 0) {
      return true;
    }

    // Get the input data
    const inputData = inputs[0][0];
    
    // Convert to 16-bit PCM
    const pcmData = new Int16Array(inputData.length);
    for (let i = 0; i < inputData.length; i++) {
      pcmData[i] = Math.max(-1, Math.min(1, inputData[i])) * 0x7FFF;
    }
    
    // Send the data to the main thread
    this.port.postMessage({
      type: "audio-data",
      audioData: pcmData.buffer
    }, [pcmData.buffer]); // Transfer the buffer to avoid copying
    
    return true;
  }
}

registerProcessor("audio-recorder-processor", AudioRecorderProcessor);
`;

// AudioPlayer class implementation
class AudioPlayer {
  constructor() {
    this.onAudioPlayedListeners = [];
    this.initialized = false;
  }

  addEventListener(event, callback) {
    switch (event) {
      case "onAudioPlayed":
        this.onAudioPlayedListeners.push(callback);
        break;
      default:
        console.error("Listener registered for event type: " + JSON.stringify(event) + " which is not supported");
    }
  }

  async start() {
    try {
      console.log("Starting AudioPlayer initialization...");
      // Use 16000 Hz for compatibility with Bedrock's output
      this.audioContext = new AudioContext({ "sampleRate": 16000 });
      console.log(`AudioContext created with sample rate: ${this.audioContext.sampleRate}`);
      
      this.analyser = this.audioContext.createAnalyser();
      this.analyser.fftSize = 512;
      console.log("Analyzer created with fftSize:", this.analyser.fftSize);

      // Create a Blob from the processor code
      const blob = new Blob([audioPlayerProcessorCode], { type: 'application/javascript' });
      const workletUrl = URL.createObjectURL(blob);
      console.log("Created worklet URL:", workletUrl);

      // Add the module to the audio context
      console.log("Adding audio worklet module...");
      await this.audioContext.audioWorklet.addModule(workletUrl);
      console.log("Audio worklet module added successfully");
      
      console.log("Creating AudioWorkletNode...");
      this.workletNode = new AudioWorkletNode(this.audioContext, "audio-player-processor");
      console.log("Connecting audio nodes...");
      this.workletNode.connect(this.analyser);
      this.analyser.connect(this.audioContext.destination);
      console.log("Audio nodes connected");
      
      // This section uses deprecated ScriptProcessorNode - keeping for backwards compatibility
      // but it's not used for the main audio playback functionality
      this.recorderNode = this.audioContext.createScriptProcessor(512, 1, 1);
      this.recorderNode.onaudioprocess = (event) => {
        // Pass the input along as-is
        const inputData = event.inputBuffer.getChannelData(0);
        const outputData = event.outputBuffer.getChannelData(0);
        outputData.set(inputData);
        // Notify listeners that the audio was played
        const samples = new Float32Array(outputData.length);
        samples.set(outputData);
        this.onAudioPlayedListeners.forEach(listener => listener(samples));
      }
      
      this.maybeOverrideInitialBufferLength();
      this.initialized = true;
      console.log("AudioPlayer initialized successfully");
      
      // Test with a short beep sound to verify audio playback works
      this.playTestSound();
    } catch (error) {
      console.error("Error initializing AudioPlayer:", error);
      throw error;
    }
  }

  async playTestSound() {
    try {
      // Create a short beep sound
      const duration = 0.3; // seconds
      const frequency = 440; // Hz
      const sampleRate = this.audioContext.sampleRate;
      const samples = new Float32Array(Math.floor(duration * sampleRate));
      
      // Generate a sine wave
      for (let i = 0; i < samples.length; i++) {
        samples[i] = Math.sin(2 * Math.PI * frequency * i / sampleRate) * 0.5;
      }
      
      console.log("Playing test sound...");
      this.playAudio(samples);
    } catch (error) {
      console.error("Error playing test sound:", error);
    }
  }

  bargeIn() {
    if (this.workletNode) {
      console.log("Sending barge-in message to worklet");
      this.workletNode.port.postMessage({
        type: "barge-in",
      });
    }
  }

  stop() {
    console.log("Stopping AudioPlayer...");
    if (ObjectExt.exists(this.audioContext)) {
      this.audioContext.close();
    }

    if (ObjectExt.exists(this.analyser)) {
      this.analyser.disconnect();
    }

    if (ObjectExt.exists(this.workletNode)) {
      this.workletNode.disconnect();
    }

    if (ObjectExt.exists(this.recorderNode)) {
      this.recorderNode.disconnect();
    }

    this.initialized = false;
    this.audioContext = null;
    this.analyser = null;
    this.workletNode = null;
    this.recorderNode = null;
    console.log("AudioPlayer stopped");
  }

  maybeOverrideInitialBufferLength() {
    // Read a user-specified initial buffer length from the URL parameters to help with tinkering
    const params = new URLSearchParams(window.location.search);
    const value = params.get("audioPlayerInitialBufferLength");
    if (value === null) {
      // Set a default buffer length (shorter for faster response)
      this.workletNode.port.postMessage({
        type: "initial-buffer-length",
        bufferLength: 4800, // 0.3 seconds at 16kHz
      });
      console.log("Using default initial buffer length: 4800 samples");
      return;
    }
    const bufferLength = parseInt(value);
    if (isNaN(bufferLength)) {
      console.error("Invalid audioPlayerInitialBufferLength value:", JSON.stringify(value));
      return;
    }
    this.workletNode.port.postMessage({
      type: "initial-buffer-length",
      bufferLength: bufferLength,
    });
    console.log(`Set custom initial buffer length: ${bufferLength}`);
  }

  playAudio(samples) {
    if (!this.initialized) {
      console.error("The audio player is not initialized. Call start() before attempting to play audio.");
      return;
    }
    
    // Resume the audio context if it's suspended (browsers require user interaction)
    if (this.audioContext.state === 'suspended') {
      console.log("Resuming suspended audio context...");
      this.audioContext.resume().then(() => {
        console.log("AudioContext resumed successfully");
        this._sendAudioToWorklet(samples);
      }).catch(err => {
        console.error("Failed to resume AudioContext:", err);
      });
    } else {
      this._sendAudioToWorklet(samples);
    }
  }
  
  _sendAudioToWorklet(samples) {
    console.log(`Sending ${samples.length} audio samples to worklet`);
    // Log some stats about the audio data
    let nonZeroCount = 0;
    let min = 1, max = -1;
    for (let i = 0; i < Math.min(1000, samples.length); i++) {
      if (samples[i] !== 0) nonZeroCount++;
      min = Math.min(min, samples[i]);
      max = Math.max(max, samples[i]);
    }
    console.log(`Audio stats: non-zero samples: ${nonZeroCount}/1000, range: ${min.toFixed(4)} to ${max.toFixed(4)}`);
    
    // ONLY use one playback method - we previously had two running simultaneously
    // Use the AudioWorkletNode for playback
    this.workletNode.port.postMessage({
      type: "audio",
      audioData: samples,
    });
  }

  getVolume() {
    if (!this.initialized) {
      return 0;
    }
    const bufferLength = this.analyser.frequencyBinCount;
    const dataArray = new Uint8Array(bufferLength);
    this.analyser.getByteTimeDomainData(dataArray);
    let normSamples = [...dataArray].map(e => e / 128 - 1);
    let sum = 0;
    for (let i = 0; i < normSamples.length; i++) {
      sum += normSamples[i] * normSamples[i];
    }
    return Math.sqrt(sum / normSamples.length);
  }
}

// Initialize audio player
async function initAudioPlayer() {
  if (audioPlayer && audioPlayer.initialized) return true;
  
  try {
    console.log("Initializing audio player...");
    audioPlayer = new AudioPlayer();
    await audioPlayer.start();
    console.log("Audio player initialized successfully");
    return true;
  } catch (error) {
    console.error("Failed to initialize audio player:", error);
    return false;
  }
}

// Simplified playAudio function that uses the AudioPlayer class
async function playAudio(float32AudioData) {
  console.log(`playAudio called with ${float32AudioData.length} samples`);
  
  if (!float32AudioData || float32AudioData.length === 0) {
    console.error("Received empty audio data");
    return;
  }
  
  if (!audioPlayer || !audioPlayer.initialized) {
    console.log("AudioPlayer not initialized, initializing now...");
    const success = await initAudioPlayer();
    if (!success) {
      console.error("Failed to initialize audio player");
      return;
    }
  }
  
  try {
    console.log("Playing audio...");
    audioPlayer.playAudio(float32AudioData);
    console.log("Audio playback started with sample count:", float32AudioData.length);
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

      async received(data) {
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
          let messageId = '';
          
          if (data.data && data.data.event && data.data.event.textOutput) {
            content = data.data.event.textOutput.content;
            // Try to get a message ID from the data
            messageId = data.data.event.id || data.data.id || JSON.stringify(data.data.event.textOutput).substring(0, 100);
          } else if (data.data && data.data.content) {
            content = data.data.content;
            messageId = data.data.id || JSON.stringify(data.data).substring(0, 100);
          } else if (data.data) {
            // If we can't find content in expected places, log the data and use stringified version
            console.warn("Unexpected textOutput structure:", data.data);
            content = JSON.stringify(data.data);
            messageId = JSON.stringify(data.data).substring(0, 100);
          }
          
          // Check if we've already processed this message to prevent duplicates
          if (content && messageId) {
            if (processedTextMessages.has(messageId)) {
              console.log("Skipping duplicate text message:", messageId);
              return;
            }
            
            // Add to processed messages
            processedTextMessages.add(messageId);
            
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
          console.log("Received audio output data");
          
          // Get audio content, handling different possible structures
          let audioContent = '';
          let audioId = '';
          
          if (data.data && data.data.event && data.data.event.audioOutput) {
            const audioOutput = data.data.event.audioOutput;
            audioContent = audioOutput.content;
            // Try to get an ID for deduplication
            audioId = data.data.event.id || data.data.id || audioOutput.content.substring(0, 50);
            
            console.log("Audio configuration:", audioOutput.mediaType, 
                      audioOutput.sampleRateHertz, 
                      audioOutput.sampleSizeBits, 
                      audioOutput.channelCount);
          } else if (data.data && data.data.content) {
            audioContent = data.data.content;
            audioId = data.data.id || data.data.content.substring(0, 50);
          } else if (data.data) {
            console.warn("Unexpected audioOutput structure:", data.data);
            console.log("Raw audioOutput data:", JSON.stringify(data));
            return; // Can't process audio without proper content
          }
          
          if (!audioContent) {
            console.error("No audio content found in output");
            return;
          }
          
          // Check if we've already processed this audio to prevent duplicates
          if (processedAudioMessages.has(audioId)) {
            console.log("Skipping duplicate audio message:", audioId);
            return;
          }
          
          // Add to processed messages
          processedAudioMessages.add(audioId);
          
          console.log(`Received audio content (length: ${audioContent.length})`);
          
          try {
            // Convert base64 to audio data and play it
            const audioData = base64ToFloat32Array(audioContent);
            
            if (audioData.length === 0) {
              console.error("Converted audio data is empty");
              return;
            }
            
            // Ensure audio context is in running state
            if (audioPlayer && audioPlayer.audioContext && audioPlayer.audioContext.state === 'suspended') {
              console.log("Audio context is suspended, attempting to resume...");
              try {
                await audioPlayer.audioContext.resume();
                console.log("Audio context resumed successfully");
              } catch (err) {
                console.error("Failed to resume audio context:", err);
              }
            }
            
            playAudio(audioData);
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

async function startRecording() {
  if (!subscription) {
    console.error("No active subscription");
    return;
  }

  // Send audio_start event before starting recording
  subscription.send({
    type: 'audio_start',
    session_id: window.sessionId
  });

  try {
    // Get microphone access
    audioStream = await navigator.mediaDevices.getUserMedia({ 
      audio: {
        sampleRate: 16000,
        channelCount: 1,
        echoCancellation: true,
        noiseSuppression: true,
        autoGainControl: true
      }
    });
    
    // Create AudioContext for processing audio
    const audioContext = new AudioContext({
      sampleRate: 16000
    });
    
    // Create a blob URL for the recorder worklet code
    const blob = new Blob([audioRecorderProcessorCode], { type: 'application/javascript' });
    const workletUrl = URL.createObjectURL(blob);
    
    // Register the worklet module
    await audioContext.audioWorklet.addModule(workletUrl);
    
    // Create audio source from stream
    const source = audioContext.createMediaStreamSource(audioStream);
    
    // Create the recorder worklet node
    const recorderNode = new AudioWorkletNode(audioContext, 'audio-recorder-processor');
    
    // Connect source to recorder
    source.connect(recorderNode);
    recorderNode.connect(audioContext.destination);
    
    // Start recording
    recorderNode.port.postMessage({
      type: 'start-recording'
    });
    
    // Listen for audio data from the worklet
    recorderNode.port.onmessage = (event) => {
      if (event.data.type === 'audio-data') {
        // Convert the audio data to base64
        const base64Data = arrayBufferToBase64(event.data.audioData);
        
        // Send to server
        if (subscription) {
          subscription.send({
            type: 'audio_input',
            audio_data: base64Data,
            session_id: window.sessionId
          });
        }
      }
    };
    
    // Store references
    recorder = {
      audioContext: audioContext,
      source: source,
      recorderNode: recorderNode,
      state: 'recording',
      stop: function() {
        this.state = 'inactive';
        // Tell the worklet to stop recording
        this.recorderNode.port.postMessage({
          type: 'stop-recording'
        });
        this.source.disconnect();
        this.recorderNode.disconnect();
        this.audioContext.close();
      }
    };
    
    document.getElementById('startButton').disabled = true;
    document.getElementById('stopButton').disabled = false;
  } catch (error) {
    console.error('Error accessing microphone:', error);
    alert('Error accessing microphone. Please ensure you have granted microphone permissions.');
  }
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

// Set up event listeners when the DOM is loaded
document.addEventListener('DOMContentLoaded', async () => {
  const startButton = document.getElementById('startButton');
  const stopButton = document.getElementById('stopButton');

  startButton.addEventListener('click', startRecording);
  stopButton.addEventListener('click', stopRecording);

  // Initialize connection
  connect();

  // Initialize audio player
  await initAudioPlayer();
}); 