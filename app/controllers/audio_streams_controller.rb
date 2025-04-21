class AudioStreamsController < ApplicationController
  def index
    # Generate a unique session ID for this streaming session
    @session_id = SecureRandom.uuid
    render :index
  end
end 