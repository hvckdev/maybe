class Provider::TinkoffAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  Provider::Factory.register("TinkoffAccount", self)

  def self.supported_account_types
    %w[Depository CreditCard]
  end

  def self.connection_configs(family:)
    return [] unless family.can_connect_tinkoff?

    [ {
      key: "tinkoff",
      name: "Tinkoff",
      description: "Connect to your bank via Tinkoff",
      can_connect: true,
      new_account_path: ->(accountable_type, return_to) {
        Rails.application.routes.url_helpers.select_accounts_tinkoff_items_path(
          accountable_type: accountable_type,
          return_to: return_to
        )
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_tinkoff_items_path(
          account_id: account_id
        )
      }
    } ]
  end

  def provider_name
    "tinkoff"
  end

  def self.build_provider(family: nil)
    return nil unless family.present?

    tinkoff_item = family.tinkoff_items.where.not(session_id: nil).first
    return nil unless tinkoff_item&.credentials_configured?

    Provider::Tinkoff.new(session_id: tinkoff_item.session_id)
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_tinkoff_item_path(item)
  end

  def item
    provider_account.tinkoff_item
  end

  def institution_domain
    "tinkoff.ru"
  end

  def institution_name
    "Tinkoff"
  end

  def institution_url
    "https://www.tinkoff.ru"
  end

  def institution_color
    "#FFDD2D"
  end
end
