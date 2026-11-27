defmodule SecantService.SecNodes.RecordingSpan do
  @moduledoc """
  A stretch of time in which a session's node was being recorded: its
  services ran, the node was connected and active, and values flowed. The
  time between spans (and after the last one) is a gap, which the plots draw
  as a break instead of joining the readings on either side (see
  `SecantService.PlotDB.Gaps`).

  Spans are written by `SecantService.RecordingTracker`, one per session.
  It generates the id, and every change is an upsert of the whole row by id
  (`:record`):

    * `alive_until` is moved on by a heartbeat while the span is open;
    * a closed span (`ended_at` set) is never changed again: the upsert's
      condition skips it, so a late heartbeat can't reopen it;
    * a session has at most one open span (a partial unique index).

  Times are the server's UTC wall-clock time, not the node's.
  """
  use Ash.Resource,
    domain: SecantService.SecNodes,
    data_layer: AshPostgres.DataLayer

  @end_reasons [:disconnected, :deactivated, :stopped, :interrupted]

  postgres do
    table "recording_spans"
    repo SecantService.Repo

    references do
      reference :sec_node do
        on_delete :delete
      end
    end

    custom_indexes do
      index [:sec_node_id, :started_at]

      index [:sec_node_id] do
        name "recording_spans_one_open_per_session_index"
        unique true
        where "ended_at IS NULL"
      end
    end
  end

  actions do
    defaults [:read, :destroy]

    create :record do
      description "Writes a span whole, by id. A closed span is left as it is."

      accept [:id, :sec_node_id, :started_at, :alive_until, :ended_at, :end_reason]
      upsert? true
      upsert_fields [:alive_until, :ended_at, :end_reason]
      upsert_condition expr(is_nil(ended_at))
      return_skipped_upsert? true
    end

    read :open_for_session do
      description "The open span of a session, if any."
      argument :sec_node_id, :uuid, allow_nil?: false
      get? true
      filter expr(sec_node_id == ^arg(:sec_node_id) and is_nil(ended_at))
    end
  end

  attributes do
    attribute :id, :uuid do
      primary_key? true
      allow_nil? false
      writable? true
      public? true
    end

    attribute :started_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :alive_until, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :ended_at, :utc_datetime_usec do
      public? true
    end

    attribute :end_reason, :atom do
      constraints one_of: @end_reasons
      public? true
    end
  end

  relationships do
    belongs_to :sec_node, SecantService.SecNodes.SecNode do
      destination_attribute :uuid
      attribute_type :uuid
      allow_nil? false
      public? true
    end
  end

  def end_reasons, do: @end_reasons
end
