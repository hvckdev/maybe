# frozen_string_literal: true

class TinkoffConnectionCleanupJob < ApplicationJob
  queue_as :default

  def perform(tinkoff_item_id:, account_id:)
    Rails.logger.info(
      "TinkoffConnectionCleanupJob - Cleaning up for former account #{account_id}"
    )

    tinkoff_item = TinkoffItem.find_by(id: tinkoff_item_id)
    return unless tinkoff_item

    # For banking providers, cleanup is typically simpler since there's no
    # separate authorization concept - the item itself holds the credentials.
    # Override this method if your provider needs specific cleanup logic.

    Rails.logger.info("TinkoffConnectionCleanupJob - Cleanup complete for account #{account_id}")
  rescue => e
    Rails.logger.warn(
      "TinkoffConnectionCleanupJob - Failed: #{e.class} - #{e.message}"
    )
    # Don't raise - cleanup failures shouldn't block other operations
  end
end
