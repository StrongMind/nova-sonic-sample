// Entry point for the build script in your package.json
import "@hotwired/turbo-rails"
import "@hotwired/stimulus"
import "@rails/actioncable"

// Import channels
import "channels/consumer"
import "channels/audio_stream"

// Import controllers
import { application } from "./controllers/application"
window.Stimulus = application 