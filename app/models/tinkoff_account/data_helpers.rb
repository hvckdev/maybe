# frozen_string_literal: true

module TinkoffAccount::DataHelpers
  extend ActiveSupport::Concern

  private

    # Convert SDK objects to hashes via JSON round-trip
    # Many SDKs return objects that don't have proper #to_h methods
    def sdk_object_to_hash(obj)
      return obj if obj.is_a?(Hash)

      if obj.respond_to?(:to_json)
        JSON.parse(obj.to_json)
      elsif obj.respond_to?(:to_h)
        obj.to_h
      else
        obj
      end
    rescue JSON::ParserError, TypeError
      obj.respond_to?(:to_h) ? obj.to_h : {}
    end

    def parse_decimal(value)
      return nil if value.nil?

      case value
      when BigDecimal
        value
      when String
        BigDecimal(value)
      when Numeric
        BigDecimal(value.to_s)
      else
        nil
      end
    rescue ArgumentError => e
      Rails.logger.error("TinkoffAccount::DataHelpers - Failed to parse decimal value: #{value.inspect} - #{e.message}")
      nil
    end

    def parse_date(date_value)
      return nil if date_value.nil?

      case date_value
      when Date
        date_value
      when String
        # Use Time.zone.parse for external timestamps (Rails timezone guidelines)
        # Handles ISO8601 formats like "2024-01-15T10:30:00+03:00"
        Time.zone.parse(date_value)&.to_date
      when Time, DateTime, ActiveSupport::TimeWithZone
        date_value.to_date
      else
        nil
      end
    rescue ArgumentError, TypeError => e
      Rails.logger.error("TinkoffAccount::DataHelpers - Failed to parse date: #{date_value.inspect} - #{e.message}")
      nil
    end

    # Handle currency as string or object (API inconsistency)
    # For Tinkoff, always defaults to "RUB"
    def extract_currency(data, fallback: "RUB")
      data = data.with_indifferent_access if data.respond_to?(:with_indifferent_access)

      currency_data = data[:currency]
      return fallback if currency_data.blank?

      if currency_data.is_a?(Hash)
        code = currency_data.with_indifferent_access[:code] || fallback
        code.upcase
      elsif currency_data.is_a?(String)
        currency_data.upcase
      else
        fallback
      end
    end
end
