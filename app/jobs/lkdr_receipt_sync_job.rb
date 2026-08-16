class LkdrReceiptSyncJob < ApplicationJob
  queue_as :default

  def perform(connection)
    connection.sync_receipts!
  rescue LkdrConnection::Client::Error => e
    Rails.logger.warn("LKDR receipt sync failed for connection #{connection.id}: #{e.class.name}")
  rescue StandardError => e
    connection.update!(status: :connected, last_error: "Unexpected receipt sync error") if connection.syncing?
    Rails.logger.error("LKDR receipt sync failed for connection #{connection.id}: #{e.class.name}")
  end
end
