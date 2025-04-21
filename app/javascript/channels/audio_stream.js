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

  navigator.mediaDevices.getUserMedia({ audio: true })
    .then(stream => {
      audioStream = stream;
      recorder = new MediaRecorder(stream);

      recorder.ondataavailable = (event) => {
        if (event.data.size > 0 && subscription) {
          const reader = new FileReader();
          reader.onloadend = () => {
            subscription.send({
              type: 'audio_input',
              audio_data: reader.result,
              session_id: window.sessionId
            });
          };
          reader.readAsDataURL(event.data);
        }
      };

      recorder.start(1000);
      document.getElementById('startButton').disabled = true;
      document.getElementById('stopButton').disabled = false;
    })
    .catch(error => {
      console.error('Error accessing microphone:', error);
      alert('Error accessing microphone. Please ensure you have granted microphone permissions.');
    });
}

function stopRecording() {
  if (recorder && recorder.state === 'recording') {
    recorder.stop();
    audioStream.getTracks().forEach(track => track.stop());
    
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