require 'excon'

module Jobs
  class EmitWebHookEvent < Jobs::Base

    def execute(args)
      [:web_hook_id, :event_type].each do |key|
        raise Discourse::InvalidParameters.new(key) unless args[key].present?
      end

      web_hook = WebHook.find_by(id: args[:web_hook_id])
      raise Discourse::InvalidParameters(:web_hook_id) if web_hook.blank?

      unless ping_event?(args[:event_type])
        return unless web_hook.active?

        return if web_hook.group_ids.present? && (args[:group_id].present? ||
          !web_hook.group_ids.include?(args[:group_id]))

        return if web_hook.category_ids.present? && (!args[:category_id].present? ||
          !web_hook.category_ids.include?(args[:category_id]))

        event_type = args[:event_type].to_s
        return unless self.send("setup_#{event_type}", args)
      end

      web_hook_request(args, web_hook)
    end

    private

    def guardian
      Guardian.new(Discourse.system_user)
    end

    def setup_post(args)
      post = Post.find_by(id: args[:post_id])
      return if post.blank?
      args[:payload] = WebHookPostSerializer.new(post, scope: guardian, root: false).as_json
    end

    def setup_topic(args)
      topic_view = (TopicView.new(args[:topic_id], Discourse.system_user) rescue nil)
      return if topic_view.blank?
      args[:payload] = WebHookTopicViewSerializer.new(topic_view, scope: guardian, root: false).as_json
    end

    def setup_user(args)
      user = User.find_by(id: args[:user_id])
      return if user.blank?
      args[:payload] = WebHookUserSerializer.new(user, scope: guardian, root: false).as_json
    end

    def ping_event?(event_type)
      event_type.to_s == 'ping'.freeze
    end

    def build_web_hook_body(args, web_hook)
      body = {}
      guardian = Guardian.new(Discourse.system_user)
      event_type = args[:event_type].to_s

      if ping_event?(event_type)
        body[:ping] = 'OK'
      else
        body[event_type] = args[:payload]
      end

      new_body = Plugin::Filter.apply(:after_build_web_hook_body, self, body)

      MultiJson.dump(new_body)
    end

    def web_hook_request(args, web_hook)
      uri = URI(web_hook.payload_url)

      conn = Excon.new(
        uri.to_s,
        ssl_verify_peer: web_hook.verify_certificate,
        retry_limit: 0
      )

      body = build_web_hook_body(args, web_hook)
      web_hook_event = WebHookEvent.create!(web_hook_id: web_hook.id)

      begin
        content_type = case web_hook.content_type
                       when WebHook.content_types['application/x-www-form-urlencoded']
                         'application/x-www-form-urlencoded'
                       else
                         'application/json'
                       end

        headers = {
          'Accept' => '*/*',
          'Connection' => 'close',
          'Content-Length' => body.bytesize,
          'Content-Type' => content_type,
          'Host' => uri.host,
          'User-Agent' => "Discourse/" + Discourse::VERSION::STRING,
          'X-Discourse-Instance' => Discourse.base_url,
          'X-Discourse-Event-Id' => web_hook_event.id,
          'X-Discourse-Event-Type' => args[:event_type]
        }

        headers['X-Discourse-Event'] = args[:event_name].to_s if args[:event_name].present?

        if web_hook.secret.present?
          headers['X-Discourse-Event-Signature'] = "sha256=" + OpenSSL::HMAC.hexdigest("sha256", web_hook.secret, body)
        end

        now = Time.zone.now
        response = conn.post(headers: headers, body: body)

        web_hook_event.update!(
          headers: MultiJson.dump(headers),
          payload: body,
          status: response.status,
          response_headers: MultiJson.dump(response.headers),
          response_body: response.body,
          duration: ((Time.zone.now - now) * 1000).to_i
        )

        MessageBus.publish("/web_hook_events/#{web_hook.id}", {
          web_hook_event_id: web_hook_event.id,
          event_type: args[:event_type]
        }, user_ids: User.human_users.staff.pluck(:id))
      rescue
        web_hook_event.destroy!
      end
    end
  end
end
