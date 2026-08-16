class LkdrConnection::Client
  include HTTParty
  extend SslConfigurable

  BASE_URL = "https://lkdr.nalog.ru".freeze
  DEVICE_INFO = {
    sourceDeviceId: "sure-finance-lkdr",
    sourceType: "WEB",
    appVersion: "1.0.0",
    metaDetails: { userAgent: "Sure Finance" }
  }.freeze

  class Error < StandardError; end
  class AuthenticationError < Error; end

  default_options.merge!({ timeout: 30 }.merge(httparty_ssl_options))

  def start_challenge(phone:, captcha_token:)
    post("/api/v2/auth/challenge/phone/start", {
      phone: phone,
      captchaToken: captcha_token,
      deviceInfo: DEVICE_INFO
    })
  end

  def verify_challenge(challenge_token:, phone:, code:)
    post("/api/v1/auth/challenge/phone/verify", {
      challengeToken: challenge_token,
      phone: phone,
      code: code,
      deviceInfo: DEVICE_INFO
    })
  end

  def refresh(refresh_token:)
    post("/api/v1/auth/token", { refreshToken: refresh_token, deviceInfo: DEVICE_INFO })
  end

  def receipts(access_token:, offset:)
    post("/api/v1/receipt", {
      limit: 100,
      offset: offset,
      dateFrom: nil,
      dateTo: nil,
      orderBy: "RECEIVE_DATE:DESC",
      inn: nil
    }, access_token: access_token)
  end

  private
    def post(path, body, access_token: nil)
      headers = { "Content-Type" => "application/json", "Accept" => "application/json" }
      headers["Authorization"] = "Bearer #{access_token}" if access_token.present?
      response = self.class.post("#{BASE_URL}#{path}", body: body.to_json, headers: headers)

      raise AuthenticationError, "LKDR authorization expired" if response.code.in?([ 401, 403 ])
      raise Error, "LKDR request failed (HTTP #{response.code})" unless response.success?

      response.parsed_response
    rescue HTTParty::Error, SocketError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout, Timeout::Error, OpenSSL::SSL::SSLError => e
      raise Error, "LKDR is unavailable: #{e.class.name}"
    end
end
