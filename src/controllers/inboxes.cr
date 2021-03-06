require "../framework/controller"
require "../framework/open"
require "../framework/signature"
require "../models/activity_pub/activity/**"
require "../models/task/deliver"

class RelationshipsController
  include Ktistec::Controller
  extend Ktistec::Open

  skip_auth ["/actors/:username/inbox"], POST

  post "/actors/:username/inbox" do |env|
    unless (account = get_account(env))
      not_found
    end
    unless (body = env.request.body.try(&.gets_to_end))
      bad_request
    end

    activity = ActivityPub::Activity.from_json_ld(body)

    if activity.id
      # mastodon reissues identifiers for accept and reject
      # activities. since these are implemented, here, as idempotent
      # operations, don't respond with conflict.
      unless activity.class.in?([ActivityPub::Activity::Accept, ActivityPub::Activity::Reject])
        conflict
      end
    end

    if activity.local?
      forbidden
    end

    # important: never use credentials in an embedded actor!

    # if the activity is signed but we don't have the actor's public
    # key, 1) fetch the actor, including their public key. 2) verify
    # the activity against the actor's public key (this will fail for
    # relays). if the activity is not signed or verification fails,
    # 3) verify the activity by retrieving it from the origin.
    # finally, 4) ensure the verified activity is associated with the
    # fetched actor.

    # 1

    if (actor_iri = activity.actor_iri)
      unless (actor = ActivityPub::Actor.find?(actor_iri)) && (!env.request.headers["Signature"]? || actor.pem_public_key)
        open?(actor_iri) do |response|
          actor = ActivityPub::Actor.from_json_ld?(response.body, include_key: true)
        end
      end
    end

    unless actor
      bad_request("Actor Not Present")
    end

    if actor.local?
      forbidden
    end

    verified = false

    # 2

    if env.request.headers["Signature"]?
      if actor && Ktistec::Signature.verify?(actor, "#{host}#{env.request.path}", env.request.headers, body)
        verified = true
      end
    end

    # 3

    unless verified
      if activity.iri.presence && (activity = ActivityPub::Activity.dereference?(activity.iri))
        verified = true
      end
    end

    unless activity && verified
      bad_request("Can't Be Verified")
    end

    # 4

    if activity.responds_to?(:actor=)
      activity.actor = actor
    end

    case activity
    when ActivityPub::Activity::Announce
      unless (object = activity.object?(dereference: true))
        bad_request
      end
      unless object.attributed_to?(dereference: true)
        bad_request
      end
    when ActivityPub::Activity::Like
      unless (object = activity.object?(dereference: true))
        bad_request
      end
      unless object.attributed_to?(dereference: true)
        bad_request
      end
    when ActivityPub::Activity::Create
      unless (object = activity.object?(dereference: true, ignore_cached: true))
        bad_request
      end
      unless activity.actor == object.attributed_to?(dereference: true)
        bad_request
      end
      object.attributed_to = activity.actor
    when ActivityPub::Activity::Update
      unless (object = activity.object?(dereference: true, ignore_cached: true))
        bad_request
      end
      unless activity.actor == object.attributed_to?(dereference: true)
        bad_request
      end
      object.attributed_to = activity.actor
    when ActivityPub::Activity::Follow
      unless actor
        bad_request
      end
      unless (object = activity.object?(dereference: true))
        bad_request
      end
      if account.actor == object
        unless Relationship::Social::Follow.find?(from_iri: actor.iri, to_iri: object.iri)
          Relationship::Social::Follow.new(
            actor: actor,
            object: object,
            visible: false
          ).save
        end
      end
      # compatibility with implementations that don't address follows
      deliver_to = [account.iri]
    when ActivityPub::Activity::Accept
      unless activity.object?.try(&.local?)
        bad_request
      end
      unless activity.object.actor == account.actor
        bad_request
      end
      unless (follow = Relationship::Social::Follow.find?(from_iri: account.actor.iri, to_iri: activity.actor.iri))
        bad_request
      end
      follow.assign(confirmed: true).save
    when ActivityPub::Activity::Reject
      unless activity.object?.try(&.local?)
        bad_request
      end
      unless activity.object.actor == account.actor
        bad_request
      end
      unless (follow = Relationship::Social::Follow.find?(from_iri: account.actor.iri, to_iri: activity.actor.iri))
        bad_request
      end
      follow.assign(confirmed: false).save
    when ActivityPub::Activity::Undo
      unless activity.actor?(dereference: true)
        bad_request
      end
      case (object = activity.object?(dereference: true))
      when ActivityPub::Activity::Announce, ActivityPub::Activity::Like
        unless object.actor == activity.actor
          bad_request
        end
        deliver_to = [account.iri]
      when ActivityPub::Activity::Follow
        unless object.object == account.actor
          bad_request
        end
        unless object.actor == activity.actor
          bad_request
        end
        unless (follow = Relationship::Social::Follow.find?(from_iri: object.actor.iri, to_iri: object.object.iri))
          bad_request
        end
        follow.destroy
        deliver_to = [account.iri]
      else
        bad_request
      end
    when ActivityPub::Activity::Delete
      unless activity.actor?(dereference: true)
        bad_request
      end
      unless activity.object?(dereference: true)
        bad_request
      end
      # fetch the object from the database because we can't trust the
      # contents of the payload. also because the original object may
      # be replaced by a tombstone (per the spec).
      if (object = ActivityPub::Object.find?(activity.object_iri))
        unless object.attributed_to? == activity.actor
          bad_request
        end
        activity.object = object
        object.delete
      elsif (object = ActivityPub::Actor.find?(activity.object_iri))
        unless object == activity.actor
          bad_request
        end
        activity.actor = activity.object = object
        object.delete
      else
        bad_request
      end
    else
      bad_request("Activity Not Supported")
    end

    activity.save

    task = Task::Deliver.new(
      sender: account.actor,
      activity: activity,
      deliver_to: deliver_to
    )
    if Kemal.config.env == "test"
      task.perform
    else
      task.schedule
    end

    ok
  end

  get "/actors/:username/inbox" do |env|
    unless (account = get_account(env))
      not_found
    end
    activities = account.actor.in_inbox(*pagination_params(env), public: env.account? != account)

    if accepts?("text/html")
      env.response.content_type = "text/html"
      render "src/views/relationships/inbox.html.ecr", "src/views/layouts/default.html.ecr"
    else
      env.response.content_type = "application/json"
      render "src/views/relationships/inbox.json.ecr"
    end
  end

  private def self.get_account(env)
    Account.find?(username: env.params.url["username"]?)
  end
end
