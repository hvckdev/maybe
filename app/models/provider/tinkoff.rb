# frozen_string_literal: true

class Provider::Tinkoff
  include HTTParty

  base_uri "https://api.tinkoff.ru/v2"
  headers "User-Agent" => "Sure Finance Tinkoff Client"
  default_options.merge!(verify: true, ssl_verify_mode: OpenSSL::SSL::VERIFY_PEER, timeout: 120)

  class Error < StandardError
    attr_reader :error_type

    def initialize(message, error_type = :unknown)
      super(message)
      @error_type = error_type
    end
  end

  class ConfigurationError < Error; end
  class AuthenticationError < Error; end

  attr_reader :session_id

  def initialize(session_id:)
    @session_id = session_id
    validate_configuration!
  end

  def list_accounts
    with_retries("list_accounts") do
      response = self.class.post(
        "/accounts",
        headers: auth_headers,
        body: {}.to_json
      )
      handle_response(response)
    end
  end

  def get_transactions(account_id:, start_date:, end_date: Date.current)
    with_retries("get_transactions") do
      response = self.class.post(
        "/operations",
        headers: auth_headers,
        body: {
          "start": start_date.beginning_of_day.to_i * 1000,
          "end": end_date.end_of_day.to_i * 1000,
          "accountKey": account_id.to_s
        }.to_json
      )
      handle_response(response)
    end
  end

  private

    RETRYABLE_ERRORS = [
      SocketError, Net::OpenTimeout, Net::ReadTimeout,
      Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::ETIMEDOUT, EOFError
    ].freeze

    MAX_RETRIES = 3
    INITIAL_RETRY_DELAY = 2

    def validate_configuration!
      raise ConfigurationError, "Session is required" if @session_id.blank?
    end

    def with_retries(operation_name, max_retries: MAX_RETRIES)
      retries = 0

      begin
        yield
      rescue *RETRYABLE_ERRORS => e
        retries += 1

        if retries <= max_retries
          delay = calculate_retry_delay(retries)
          Rails.logger.warn(
            "Tinkoff API: #{operation_name} failed (attempt #{retries}/#{max_retries}): " \
            "#{e.class}: #{e.message}. Retrying in #{delay}s..."
          )
          sleep(delay)
          retry
        else
          Rails.logger.error(
            "Tinkoff API: #{operation_name} failed after #{max_retries} retries: " \
            "#{e.class}: #{e.message}"
          )
          raise Error.new("Network error after #{max_retries} retries: #{e.message}", :network_error)
        end
      end
    end

    def calculate_retry_delay(retry_count)
      base_delay = INITIAL_RETRY_DELAY * (2 ** (retry_count - 1))
      jitter = base_delay * rand * 0.25
      [ base_delay + jitter, 30 ].min
    end

    def auth_headers
      {
        "Content-Type" => "application/json",
        "Accept" => "application/json",
        "Cookie" => "sessionid=#{@session_id}"
      }
    end

    def handle_response(response)
      case response.code
      when 200
        JSON.parse(response.body, symbolize_names: true)
      when 400
        Rails.logger.error "Tinkoff API: Bad request - #{response.body}"
        raise Error.new("Bad request: #{response.body}", :bad_request)
      when 401
        raise AuthenticationError.new("Invalid session", :unauthorized)
      when 403
        raise AuthenticationError.new("Access forbidden - session expired", :access_forbidden)
      when 429
        raise Error.new("Rate limit exceeded. Please try again later.", :rate_limited)
      when 500..599
        raise Error.new("Tinkoff server error (#{response.code}). Please try again later.", :server_error)
      else
        Rails.logger.error "Tinkoff API: Unexpected response - Code: #{response.code}, Body: #{response.body}"
        raise Error.new("Unexpected error: #{response.code} - #{response.body}", :unknown)
      end
    end
end
