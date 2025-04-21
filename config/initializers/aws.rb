require 'aws-sdk-bedrockruntime'

Aws.config.update({
  region: ENV['AWS_REGION'] || 'us-east-1',
  credentials: Aws::Credentials.new(
    ENV['AWS_ACCESS_KEY_ID'],
    ENV['AWS_SECRET_ACCESS_KEY']
  )
}) if Rails.env.production?

# Use local credentials in development
if Rails.env.development?
  Aws.config.update({
    region: ENV['AWS_REGION'] || 'us-east-1',
    credentials: Aws::Credentials.new(
      ENV['AWS_ACCESS_KEY_ID'] || 'your-access-key',
      ENV['AWS_SECRET_ACCESS_KEY'] || 'your-secret-key'
    )
  })
end 