# frozen_string_literal: true

class PendingPostSerializer < ApplicationSerializer

  attributes :id,
             :category_id,
             :created_at,
             :created_by_id,
             :raw_text,
             :title,
             :topic_id,
             :topic_url

  delegate :payload, :topic, to: :object, private: true
  delegate :url, to: :topic, prefix: true, allow_nil: true

  # payload_attributes :raw,
  #                    :title,
  #                    :category,
  #                    :tags,
  #                    :via_email,
  #                    :raw_email

  def raw_text
    payload["raw"]
  end

  def title
    payload["title"]
  end
end
