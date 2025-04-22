require 'test_helper'
require 'securerandom'

class NovaSonicBidirectionalStreamClientTest < ActiveSupport::TestCase
  setup do
    # Mock the AWS credentials for testing
    @credentials = {
      access_key_id: 'test_access_key',
      secret_access_key: 'test_secret_key'
    }
    
    # Stub the AWS client to prevent actual AWS calls
    Aws::BedrockRuntime::AsyncClient.stub_any_instance(:invoke_model_with_bidirectional_stream, 
      lambda { |*args|
        # Mock async response with a wait method
        mock_response = Minitest::Mock.new
        mock_response.expect(:wait, nil)
        mock_response
      }
    )
    
    # Create the client
    @client = NovaSonicBidirectionalStreamClient.new(
      region: 'us-east-1',
      credentials: @credentials
    )
  end
  
  test "create_stream_session creates a new session" do
    session_id = SecureRandom.uuid
    session = @client.create_stream_session(session_id)
    
    assert_equal session_id, session.session_id
    assert @client.active_sessions.key?(session_id)
    assert @client.is_session_active(session_id)
  end
  
  test "create_stream_session without ID generates a UUID" do
    session = @client.create_stream_session
    
    assert_not_nil session.session_id
    assert @client.active_sessions.key?(session.session_id)
  end
  
  test "create_stream_session raises error for duplicate session ID" do
    session_id = SecureRandom.uuid
    @client.create_stream_session(session_id)
    
    assert_raises(RuntimeError) do
      @client.create_stream_session(session_id)
    end
  end
  
  test "get_active_sessions returns all active session IDs" do
    session1 = @client.create_stream_session
    session2 = @client.create_stream_session
    
    active_sessions = @client.get_active_sessions
    
    assert_includes active_sessions, session1.session_id
    assert_includes active_sessions, session2.session_id
    assert_equal 2, active_sessions.size
  end
  
  test "force_close_session removes session" do
    session = @client.create_stream_session
    
    assert @client.is_session_active(session.session_id)
    
    @client.force_close_session(session.session_id)
    
    assert_not @client.active_sessions.key?(session.session_id)
  end
  
  test "stream_audio_chunk adds to session queue" do
    # This test validates the method exists and doesn't raise errors
    session = @client.create_stream_session
    
    # Set up the session for audio streaming
    session_data = @client.active_sessions[session.session_id]
    session_data[:is_audio_content_start_sent] = true
    
    # Create a simple audio buffer
    audio_data = "test audio data".bytes.pack('c*')
    
    # Should not raise an error
    assert_nothing_raised do
      @client.stream_audio_chunk(session.session_id, audio_data)
    end
  end
  
  test "on_event registers event handlers" do
    session = @client.create_stream_session
    
    # Register a handler
    test_var = nil
    session.on_event('testEvent') do |data|
      test_var = data
    end
    
    # Trigger the event manually
    session.handle_event('testEvent', 'test_data')
    
    assert_equal 'test_data', test_var
  end
end 