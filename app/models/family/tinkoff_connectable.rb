module Family::TinkoffConnectable
  extend ActiveSupport::Concern

  included do
    has_many :tinkoff_items, dependent: :destroy
  end

  def can_connect_tinkoff?
    # Families can configure their own Tinkoff credentials
    true
  end

  def create_tinkoff_item!(session_id:, item_name: nil)
    tinkoff_item = tinkoff_items.create!(
      name: item_name || "Tinkoff Connection",
      session_id: session_id
    )

    tinkoff_item.sync_later

    tinkoff_item
  end

  def has_tinkoff_credentials?
    tinkoff_items.where.not(session_id: nil).exists?
  end
end
