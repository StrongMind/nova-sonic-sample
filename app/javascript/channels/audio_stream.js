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
      
      // Removed test beep sound
    } catch (error) {
      console.error("Error initializing AudioPlayer:", error);
      throw error;
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
  // Reset reconnection counter if this is a manual connection
  if (subscription === null) {
    reconnectAttempts = 0;
  }
  
  // Update UI to show connecting state
  updateConnectionStatus("Connecting to Nova Sonic...", false);
  
  // Disable buttons while connecting
  document.getElementById('startButton').disabled = true;
  document.getElementById('stopButton').disabled = true;
  
  // Clean up existing subscription if any
  if (subscription) {
    console.log("Cleaning up existing subscription before reconnect");
    subscription.unsubscribe();
    subscription = null;
  }
  
  // Create a new subscription with the session ID
  console.log(`Creating subscription with session ID: ${window.sessionId}`);
  subscription = consumer.subscriptions.create(
    { channel: "AudioStreamChannel", session_id: window.sessionId },
    {
      connected() {
        console.log("Connected to AudioStreamChannel");
        reconnectAttempts = 0; // Reset counter on successful connection
      },
      
      disconnected() {
        console.log("Disconnected from AudioStreamChannel");
        updateConnectionStatus("Disconnected", false);
        
        // Disable recording buttons
        document.getElementById('startButton').disabled = true;
        document.getElementById('stopButton').disabled = true;
        
        // Only try to reconnect if we haven't exceeded max attempts
        if (reconnectAttempts < MAX_RECONNECT_ATTEMPTS) {
          reconnectAttempts++;
          
          // Exponential backoff for reconnection
          const delay = Math.min(1000 * Math.pow(2, reconnectAttempts), 30000); // Max 30-second delay
          console.log(`Attempting to reconnect (attempt ${reconnectAttempts}/${MAX_RECONNECT_ATTEMPTS}) in ${delay/1000} seconds...`);
          
          updateConnectionStatus(`Reconnecting in ${delay/1000} seconds... (${reconnectAttempts}/${MAX_RECONNECT_ATTEMPTS})`, false);
          
          setTimeout(() => {
            console.log(`Reconnecting now (attempt ${reconnectAttempts}/${MAX_RECONNECT_ATTEMPTS})`);
            connect();
          }, delay);
        } else {
          console.log("Max reconnection attempts reached. Please refresh the page.");
          updateConnectionStatus("Connection failed. Please refresh the page.", false);
          appendMessage("Connection error: Maximum reconnection attempts reached. Please refresh the page to continue.");
        }
      },
      
      rejected() {
        console.log("Subscription was rejected");
        updateConnectionStatus("Connection rejected", false);
      },
      
      async received(data) {
        try {
          if (data.type === 'error') {
            console.error(`Error from server:`, data);
            
            // Add error message to chat
            let errorMsg = `Error: ${data.message}`;
            if (data.details) {
              errorMsg += ` - ${data.details}`;
            }
            appendMessage(errorMsg);
            
            // Update connection status
            updateConnectionStatus(`Error: ${data.message}`, false);
            
            // Handle specific error types
            if (data.error_type) {
              console.log(`Detected error type: ${data.error_type}`);
              
              // Credential issues
              if (data.credential_status === 'issue') {
                console.warn("AWS credential issue detected");
                appendMessage("AWS credential issue detected. You may need to refresh your credentials.");
              }
              
              // ValidationException errors
              if (data.error_type === 'validation_exception' || data.error_type === 'invalid_input') {
                console.warn("AWS validation error detected");
                
                // Stop current recording if active
                if (recorder && recorder.state === 'recording') {
                  await stopRecording();
                  appendMessage("Recording stopped due to validation error");
                }
                
                // Force audio player refresh
                if (audioPlayer) {
                  try {
                    audioPlayer.stop();
                    audioPlayer = null;
                    await initAudioPlayer();
                    console.log("Audio player reset after validation error");
                  } catch (e) {
                    console.error("Failed to reset audio player:", e);
                  }
                }
              }
            }
            
            // Session not found case - attempt recovery
            if (data.details && 
                (data.details.includes('Session not found or inactive') || 
                 data.details.includes('not active or not found'))) {
              
              console.log("Session not found error detected, will try to recover automatically");
              
              // Stop current recording if active
              if (recorder && recorder.state === 'recording') {
                await stopRecording();
              }
              
              // Wait a moment before reconnecting
              setTimeout(() => {
                console.log("Attempting to reconnect after session not found error");
                connect();
              }, 1500);
            }
            
            // If server suggests a recovery action
            if (data.recovery_action === 'refresh_page') {
              console.log("Server suggests refreshing the page");
              appendMessage("Connection error. Please refresh the page to reconnect.");
              
              // Disable buttons
              document.getElementById('startButton').disabled = true;
              document.getElementById('stopButton').disabled = true;
            }
            
            return;
          }
          
          // Handle session recovery messages
          if (data.type === 'session_recovered' || data.type === 'session_recreated') {
            console.log(`Session recovery status: ${data.message}`);
            updateConnectionStatus(`Session recovered: ${data.message}`, true);
            return;
          }
          
          // Handle connection confirmation
          if (data.type === 'connected' || data.type === 'session_ready') {
            console.log("Connection established with session ID:", data.session_id || window.sessionId);
            updateConnectionStatus("Connected to Nova Sonic", true);
            
            // Enable start button
            document.getElementById('startButton').disabled = false;
            document.getElementById('stopButton').disabled = true;
            
            return;
          }
          
          // Handle pong response
          if (data.type === 'pong') {
            console.log("Received pong from server:", data);
            return;
          }
          
          // Handle audio output
          if (data.type === 'audioOutput') {
            // Extract the audio content
            try {
              const audioData = data.data.event.audioOutput;
              const audioContent = audioData.content;
              
              // Check if we have a non-empty content string
              if (audioContent && typeof audioContent === 'string' && audioContent.trim().length > 0) {
                const messageId = audioData.promptName + '_' + audioData.contentName;
                
                // Skip duplicates
                if (processedAudioMessages.has(messageId)) {
                  console.log(`Skipping duplicate audio message: ${messageId}`);
                  return;
                }
                
                processedAudioMessages.add(messageId);
                
                // Convert base64 audio to Float32Array and play it
                const float32Samples = base64ToFloat32Array(audioContent);
                if (float32Samples && float32Samples.length > 0) {
                  await playAudio(float32Samples);
                } else {
                  console.warn("Received empty audio samples from base64 conversion");
                }
              } else {
                console.log("Received empty audio content");
              }
            } catch (e) {
              console.error("Error processing audio output:", e);
            }
            return;
          }
          
          // Handle text output
          if (data.type === 'textOutput') {
            try {
              const textData = data.data.event.textOutput;
              const textContent = textData.content;
              
              const messageId = textData.promptName + '_' + textData.contentName;
              
              // Skip duplicates
              if (processedTextMessages.has(messageId)) {
                console.log(`Skipping duplicate text message: ${messageId}`);
                return;
              }
              
              processedTextMessages.add(messageId);
              
              if (textContent && textContent.trim().length > 0) {
                // Add message to chat
                appendMessage("Nova: " + textContent);
              }
            } catch (e) {
              console.error("Error processing text output:", e);
            }
            return;
          }
          
          // Handle tool use
          if (data.type === 'toolUse') {
            try {
              const toolData = data.data.event.toolUse;
              const toolName = toolData.toolName;
              console.log(`Tool use request: ${toolName}`);
              
              // This is just a demo implementation - in a real app, you'd handle the tool
              // based on its name and send tool results back
              appendMessage(`[Tool] Nova wants to use: ${toolName}`);
            } catch (e) {
              console.error("Error processing tool use:", e);
            }
            return;
          }
          
          // Handle content end (useful for UI markers)
          if (data.type === 'contentEnd') {
            try {
              const contentData = data.data.event.contentEnd;
              console.log(`Content end marker: ${contentData.contentName}`);
            } catch (e) {
              console.error("Error processing content end:", e);
            }
            return;
          }
          
          // Handle all other message types (just log them)
          console.log(`Received message of type ${data.type}:`, data);
          
        } catch (e) {
          console.error("Error processing message:", e);
        }
      }
    }
  );
  
  // Send a ping to ensure connection is working
  setTimeout(() => {
    try {
      if (subscription && subscription.send) {
        subscription.send({type: 'ping', timestamp: Date.now()});
      }
    } catch (e) {
      console.error("Error sending ping:", e);
    }
  }, 2000);
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

  // If we already have a recorder, clean it up
  if (recorder && recorder.state === 'recording') {
    console.log("Stopping existing recording before starting new one");
    stopRecording();
    // Small delay to ensure cleanup
    await new Promise(resolve => setTimeout(resolve, 100));
  }

  try {
    // Initialize audio configuration
    const audioConfig = {
      sampleRate: 16000,
      channelCount: 1,
      bitsPerSample: 16
    };
    
    console.log(`Setting up audio capture with ${audioConfig.sampleRate}Hz, ${audioConfig.channelCount} channel, ${audioConfig.bitsPerSample}-bit`);

    // Get microphone access with explicit constraints
    audioStream = await navigator.mediaDevices.getUserMedia({ 
      audio: {
        sampleRate: audioConfig.sampleRate,
        channelCount: audioConfig.channelCount,
        echoCancellation: true,
        noiseSuppression: true,
        autoGainControl: true
      }
    });
    
    // Create AudioContext with explicit sample rate
    const audioContext = new AudioContext({
      sampleRate: audioConfig.sampleRate
    });
    
    // Check actual sample rate
    console.log(`Actual AudioContext sample rate: ${audioContext.sampleRate}Hz`);
    
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
    
    // Buffer to accumulate audio data
    let audioBuffer = [];
    const CHUNK_SIZE = 4000; // 0.125s at 16kHz, 16-bit
    
    // Start recording
    recorderNode.port.postMessage({
      type: 'start-recording'
    });
    
    // Listen for audio data from the worklet
    recorderNode.port.onmessage = (event) => {
      if (event.data.type === 'audio-data') {
        // Get the audio data as Int16Array
        const audioData = new Int16Array(event.data.audioData);
        
        // Add to buffer
        audioBuffer.push(...audioData);
        
        // When we have enough data, send a chunk
        if (audioBuffer.length >= CHUNK_SIZE) {
          // Create a chunk from the buffer
          const chunk = new Int16Array(audioBuffer.slice(0, CHUNK_SIZE));
          
          // Convert to base64
          const base64Data = arrayBufferToBase64(chunk.buffer);
          
          // Send to server
          if (subscription) {
            subscription.send({
              type: 'audio_data',
              audio: base64Data,
              session_id: window.sessionId
            });
          }
          
          // Keep remaining data
          audioBuffer = audioBuffer.slice(CHUNK_SIZE);
        }
      }
    };
    
    // Store references
    recorder = {
      audioContext: audioContext,
      source: source,
      recorderNode: recorderNode,
      state: 'recording',
      audioBuffer: audioBuffer,
      stop: function() {
        this.state = 'inactive';
        // Tell the worklet to stop recording
        this.recorderNode.port.postMessage({
          type: 'stop-recording'
        });
        
        // Send any remaining audio in buffer
        if (this.audioBuffer && this.audioBuffer.length > 0) {
          const remainingChunk = new Int16Array(this.audioBuffer);
          const base64Data = arrayBufferToBase64(remainingChunk.buffer);
          
          if (subscription) {
            subscription.send({
              type: 'audio_data',
              audio: base64Data,
              session_id: window.sessionId
            });
          }
        }
        
        this.source.disconnect();
        this.recorderNode.disconnect();
        this.audioContext.close();
      }
    };
    
    // If we have an audio player, do a barge-in
    if (audioPlayer && audioPlayer.initialized) {
      console.log("Performing barge-in on existing audio playback");
      audioPlayer.bargeIn();
    }
    
    document.getElementById('startButton').disabled = true;
    document.getElementById('stopButton').disabled = false;
  } catch (error) {
    console.error('Error accessing microphone:', error);
    alert('Error accessing microphone. Please ensure you have granted microphone permissions.');
    
    // Re-enable the start button on error
    document.getElementById('startButton').disabled = false;
    document.getElementById('stopButton').disabled = true;
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
    console.log("Stopping recording");
    recorder.stop();
    
    if (audioStream) {
      audioStream.getTracks().forEach(track => track.stop());
      audioStream = null;
    }
    
    if (subscription) {
      console.log("Sending stop_audio event");
      subscription.send({
        type: 'stop_audio',
        session_id: window.sessionId
      });
    }
    
    // Clean up recorder
    recorder = null;
    
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