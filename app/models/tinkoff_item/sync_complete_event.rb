# frozen_string_literal: true

class TinkoffItem::SyncCompleteEvent
  attr_reader :tinkoff_item

  def initialize(tinkoff_item)
    @tinkoff_item = tinkoff_item
  end

  def broadcast
    tinkoff_item.accounts.each do |account|
      account.broadcast_sync_complete
    end

    tinkoff_item.broadcast_replace_to(
      tinkoff_item.family,
      target: "tinkoff_item_#{tinkoff_item.id}",
      partial: "tinkoff_items/tinkoff_item",
      locals: { tinkoff_item: tinkoff_item }
    )

    tinkoff_item.family.broadcast_sync_complete
  end
end
