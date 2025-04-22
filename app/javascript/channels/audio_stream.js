import consumer from "./consumer"

let recorder = null;
let audioStream = null;
let subscription = null;
let reconnectAttempts = 0;
const MAX_RECONNECT_ATTEMPTS = 5;

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
        if (data.type === 'confirm_subscription') {
          console.log("Subscription confirmed");
          document.getElementById('startButton').disabled = false;
        }
        if (data.message) {
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

// Set up event listeners when the DOM is loaded
document.addEventListener('DOMContentLoaded', () => {
  const startButton = document.getElementById('startButton');
  const stopButton = document.getElementById('stopButton');

  startButton.addEventListener('click', startRecording);
  stopButton.addEventListener('click', stopRecording);

  // Initialize connection
  connect();
}); 