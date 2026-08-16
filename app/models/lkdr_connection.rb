class LkdrConnection < ApplicationRecord
  include Encryptable

  has_many :lkdr_receipts, through: :family
  belongs_to :family

  encrypts :refresh_token if encryption_ready?
  encrypts :challenge_token if encryption_ready?

  enum :status, { pending: "pending", connected: "connected", syncing: "syncing", requires_reauth: "requires_reauth" }, default: :pending

  validates :family_id, uniqueness: true
  validates :phone, presence: true

  def challenge_pending?
    challenge_token.present? && challenge_expires_at&.future?
  end

  def start_challenge!(captcha_token:)
    response = client.start_challenge(phone: phone, captcha_token: captcha_token)
    update!(
      challenge_token: response.fetch("challengeToken"),
      challenge_expires_at: challenge_expiry(response),
      status: :pending,
      last_error: nil
    )
  end

  def verify!(code:)
    raise LkdrConnection::Client::Error, "SMS verification has expired" unless challenge_pending?

    response = client.verify_challenge(challenge_token: challenge_token, phone: phone, code: code)
    update!(
      refresh_token: response.fetch("refreshToken"),
      challenge_token: nil,
      challenge_expires_at: nil,
      status: :connected,
      last_error: nil
    )
  end

  def sync_later
    return if syncing?

    update!(status: :syncing, last_error: nil)
    LkdrReceiptSyncJob.perform_later(self)
  end

  def sync_receipts!
    token_response = client.refresh(refresh_token: refresh_token)
    access_token = token_response.fetch("token")
    refresh_token = token_response["refreshToken"].presence || self.refresh_token
    offset = 0
    imported_count = 0

    loop do
      payload = client.receipts(access_token: access_token, offset: offset)
      receipts = Array(payload["receipts"])
      receipts.each do |receipt|
        upsert_receipt!(receipt)
        imported_count += 1
      end

      break unless payload["hasMore"] && receipts.any?

      offset += receipts.length
    end

    update!(refresh_token: refresh_token, status: :connected, last_synced_at: Time.current, last_error: nil)
    imported_count
  rescue LkdrConnection::Client::AuthenticationError => e
    update!(status: :requires_reauth, last_error: e.message)
    raise
  rescue LkdrConnection::Client::Error => e
    update!(status: :connected, last_error: e.message)
    raise
  end

  private
    def client
      @client ||= LkdrConnection::Client.new
    end

    def challenge_expiry(response)
      expires_at = response["challengeTokenExpiresIn"] || response["challengeExpiresAt"]
      return expires_at.to_time if expires_at.present?

      Time.current + response.fetch("challengeTokenExpiresInSec").to_i.seconds
    end

    def upsert_receipt!(payload)
      receipt = family.lkdr_receipts.find_or_initialize_by(external_key: payload.fetch("key"))
      receipt.assign_attributes(
        merchant_name: payload["kktOwner"].presence || "Unknown merchant",
        merchant_inn: payload["kktOwnerInn"],
        purchased_at: Date.parse(payload.fetch("createdDate")),
        total_amount: payload.fetch("totalSum").to_d,
        currency: "RUB",
        fiscal_drive_number: payload["fiscalDriveNumber"],
        fiscal_document_number: payload["fiscalDocumentNumber"],
        fiscal_sign: payload["fiscalSign"],
        raw_payload: payload
      )
      receipt.save!
    end
end
