module Timeline::Track
  extend ActiveSupport::Concern

  module ClassMethods
    def track(name, options={})
      @name = name
      @callback = options.delete :on
      @callback ||= :create
      @actor = options.delete :actor
      @actor ||= :creator
      @object = options.delete :object
      @target = options.delete :target
      @followers = options.delete :followers
      @followers ||= :followers
      @mentionable = options.delete :mentionable

      method_name = "track_#{@name}_after_#{@callback}".to_sym
      define_activity_method method_name, actor: @actor, object: @object, target: @target, followers: @followers, verb: name, mentionable: @mentionable

      send "after_#{@callback}".to_sym, method_name, if: options.delete(:if)
    end

    private

      def define_activity_method(method_name, options={})
        define_method method_name do
          redis_proof do
          @fields_for = {}
          @object = set_object(options[:object])
          if options[:actor] == :self
            @actor = @object
          else
            @actor = send(options[:actor])
          end
          unless @actor
            logger.error "bad actor aborting timeline track for #{self.inspect}: #{@actor.inspect}"
            return 
          end
          @target = !options[:target].nil? ? send(options[:target].to_sym) : nil
          @extra_fields ||= nil
          follower_method = options[:followers].to_sym
          @followers = @actor.respond_to?(follower_method) ? @actor.send(follower_method) : []
          @mentionable = options[:mentionable]
          add_activity activity(verb: options[:verb])
        end
        end
      end
  end

  protected

    def redis_proof
      yield
    rescue Redis::CannotConnectError => e
      logger.error "Timeline Audit Error: Redis::CannotConnectError: #{e.inspect}"
      true
    end


    def activity(options={})
      {
        verb: options[:verb],
        actor: options_for(@actor, options[:verb]),
        object: options_for(@object, options[:verb]),
        target: options_for(@target, options[:verb]),
        created_at: Time.now
      }
    end

    def add_activity(activity_item)
      redis_add "global:activity", activity_item
      add_activity_to_user(activity_item[:actor][:id], activity_item)
      #add_activity_by_user(activity_item[:actor][:id], activity_item)
      add_mentions(activity_item)
      add_activity_to_followers(activity_item) if @followers.any?
    end

    def add_activity_by_user(user_id, activity_item)
      #redis_add "user:id:#{user_id}:posts", activity_item
    end

    def add_activity_to_user(user_id, activity_item)
      redis_add "user:id:#{user_id}:activity", activity_item
    end

    def add_activity_to_followers(activity_item)
      @followers.each { |follower| add_activity_to_user(follower.id, activity_item) }
    end

    def add_mentions(activity_item)
      return unless @mentionable and @object.send(@mentionable)
      @object.send(@mentionable).scan(/@\w+/).each do |mention|
        if user = @actor.class.find_by_username(mention[1..-1])
          add_mention_to_user(user.id, activity_item)
        end
      end
    end

    def add_mention_to_user(user_id, activity_item)
      redis_add "user:id:#{user_id}:mentions", activity_item
    end

    def extra_fields_for(object,verb)
      object.respond_to?(:timeline_fields_for) ? object.send(:timeline_fields_for, verb) : {}
    end

    def options_for(target, verb)
      if !target.nil?
        {
          id: target.id,
          class: target.class.to_s,
          display_name: target.to_s
        }.merge(extra_fields_for(target, verb))
      else
        nil
      end
    end

    def redis_add(list, activity_item)
      Timeline.redis.lpush list, Timeline.encode(activity_item)
    end

    def set_object(object)
      case
      when object.is_a?(Symbol)
        send(object)
      when object.is_a?(Array)
        @fields_for[self.class.to_s.downcase.to_sym] = object
        self
      else
        self
      end
    end

end
