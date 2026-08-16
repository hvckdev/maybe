class LkdrReceipt < ApplicationRecord
  include Encryptable

  SOURCE = "lkdr".freeze

  encrypts :raw_payload if encryption_ready?

  belongs_to :family
  belongs_to :entry, optional: true

  validates :external_key, :merchant_name, :purchased_at, :currency, presence: true
  validates :total_amount, numericality: { greater_than: 0 }
  validates :external_key, uniqueness: { scope: :family_id }
  validate :entry_belongs_to_family

  scope :ordered, -> { order(purchased_at: :desc, created_at: :desc) }
  scope :unimported, -> { where(entry_id: nil) }

  def imported?
    entry_id.present?
  end

  # Imports a receipt as an expense. The LKDR fiscal key is used as the external
  # ID so a retry cannot create another expense in the same account.
  def import_into!(account:)
    raise ArgumentError, "Account must belong to the receipt family" unless account.family_id == family_id

    transaction do
      return entry if imported?

      imported_entry = account.entries.find_or_initialize_by(source: SOURCE, external_id: external_key)
      if imported_entry.new_record?
        imported_entry.assign_attributes(
          entryable: Transaction.new(extra: { SOURCE => receipt_metadata }),
          name: merchant_name,
          date: purchased_at,
          amount: total_amount,
          currency: currency,
          notes: fiscal_details,
          import_locked: true
        )
        imported_entry.save!
      end

      update!(entry: imported_entry)
      imported_entry
    end
  end

  private
    def receipt_metadata
      {
        "external_key" => external_key,
        "merchant_inn" => merchant_inn,
        "fiscal_drive_number" => fiscal_drive_number,
        "fiscal_document_number" => fiscal_document_number,
        "fiscal_sign" => fiscal_sign
      }.compact
    end

    def fiscal_details
      [
        "Imported from My Receipts Online (FNS).",
        ("Merchant INN: #{merchant_inn}" if merchant_inn.present?),
        ("Fiscal drive number: #{fiscal_drive_number}" if fiscal_drive_number.present?),
        ("Fiscal document number: #{fiscal_document_number}" if fiscal_document_number.present?)
      ].compact.join("\n")
    end

    def entry_belongs_to_family
      return unless entry && entry.account.family_id != family_id

      errors.add(:entry, "must belong to the same family")
    end
end
