module ModelApi
  module BaseController
    module ClassMethods
      def model_class
        nil
      end
      
      def base_api_options
        {}
      end
      
      def base_admin_api_options
        base_api_options.merge(admin_only: true)
      end
    end
    
    class << self
      def included(base)
        base.extend(ClassMethods)
        
        base.send(:include, InstanceMethods)
        
        base.send(:before_filter, :common_headers)
        
        base.send(:rescue_from, Exception, with: :unhandled_exception)
        base.send(:respond_to, :json, :xml)
      end
    end
    
    module InstanceMethods
      SIMPLE_ID_REGEX = /\A[0-9]+\Z/
      UUID_REGEX = /\A[0-9A-Za-z]{8}-?[0-9A-Za-z]{4}-?[0-9A-Za-z]{4}-?[0-9A-Za-z]{4}-?[0-9A-Za-z]\
          {12}\Z/x
      DEFAULT_PAGE_SIZE = 100
      
      protected
      
      def model_class
        self.class.model_class
      end
      
      def render_collection(collection, opts = {})
        return unless ensure_admin_if_admin_only(opts)
        opts = prepare_options(opts)
        opts[:operation] ||= :index
        return unless validate_read_operation(collection, opts[:operation], opts)
        
        coll_route = opts[:collection_route] || self
        collection_links = { self: coll_route }
        collection = ModelApi::Utils.process_collection_includes(collection,
            opts.merge(model_metadata: opts[:api_model_metadata] || opts[:model_metadata]))
        collection, _result_filters = filter_collection(collection, find_filter_params, opts)
        collection, _result_sorts = sort_collection(collection, find_sort_params, opts)
        collection, collection_links, opts = paginate_collection(collection,
            collection_links, opts, coll_route)
        
        opts[:collection_links] = collection_links.merge(opts[:collection_links] || {})
            .reverse_merge(common_response_links(opts))
        add_collection_object_route(opts)
        ModelApi::Renderer.render(self, collection, opts)
      end
      
      def render_object(obj, opts = {})
        return unless ensure_admin_if_admin_only(opts)
        opts = prepare_options(opts)
        klass = ModelApi::Utils.find_class(obj, opts)
        object_route = opts[:object_route] || self
        
        opts[:object_links] = { self: object_route }
        if obj.is_a?(ActiveRecord::Base)
          return unless validate_read_operation(obj, opts[:operation], opts)
          unless obj.present?
            return not_found(opts.merge(class: klass, field: :id))
          end
          opts[:object_links].merge!(opts[:object_links] || {})
        else
          return not_found(opts) if obj.nil?
          obj = ModelApi::Utils.ext_value(obj, opts) unless opts[:raw_output]
          opts[:object_links].merge!(opts[:links] || {})
        end
        
        opts[:operation] ||= :show
        opts[:object_links].reverse_merge!(common_response_links(opts))
        ModelApi::Renderer.render(self, obj, opts)
      end
      
      def do_create(opts = {})
        klass = opts[:model_class] || model_class
        return unless ensure_admin_if_admin_only(opts)
        unless klass.is_a?(Class) && klass < ActiveRecord::Base
          fail 'Unable to process object creation; Missing or invalid model class'
        end
        obj, opts = prepare_object_for_create(klass, opts)
        return bad_payload(class: klass) if opts[:bad_payload]
        create_and_render_object(obj, opts)
      end
      
      def prepare_object_for_create(klass, opts = {})
        opts = prepare_options(opts)
        get_updated_object(klass, get_operation(:create, opts), opts)
      end
      
      def create_and_render_object(obj, opts = {})
        opts = prepare_options(opts)
        object_link_options = opts[:object_link_options]
        object_link_options[:action] = :show
        save_and_render_object(obj, get_operation(:create, opts), opts.merge(location_header: true))
      end
      
      def do_update(obj, opts = {})
        return unless ensure_admin_if_admin_only(opts)
        obj, opts = prepare_object_for_update(obj, opts)
        return bad_payload(class: klass) if opts[:bad_payload]
        unless obj.present?
          return not_found(opts.merge(class: ModelApi::Utils.find_class(obj, opts), field: :id))
        end
        update_and_render_object(obj, opts)
      end
      
      def prepare_object_for_update(obj, opts = {})
        opts = prepare_options(opts)
        get_updated_object(obj, get_operation(:update, opts), opts)
      end
      
      def update_and_render_object(obj, opts = {})
        opts = prepare_options(opts)
        save_and_render_object(obj, get_operation(:update, opts), opts)
      end
      
      def save_and_render_object(obj, operation, opts = {})
        status, msgs = Utils.process_updated_model_save(obj, operation, opts)
        add_hateoas_links_for_updated_object(operation, opts)
        successful = ModelApi::Utils.response_successful?(status)
        ModelApi::Renderer.render(self, successful ? obj : opts[:request_obj],
            opts.merge(status: status, operation: :show, messages: msgs))
      end
      
      def do_destroy(obj, opts = {})
        return unless ensure_admin_if_admin_only(opts)
        opts = prepare_options(opts)
        obj = obj.first if obj.is_a?(ActiveRecord::Relation)
        
        add_hateoas_links_for_update(opts)
        unless obj.present?
          return not_found(opts.merge(class: klass, field: :id))
        end
        
        operation = opts[:operation] = get_operation(:destroy, opts)
        ModelApi::Utils.validate_operation(obj, operation,
            opts.merge(model_metadata: opts[:api_model_metadata] || opts[:model_metadata]))
        response_status, errs_or_msgs = Utils.process_object_destroy(obj, operation, opts)
        
        add_hateoas_links_for_updated_object(operation, opts)
        klass = ModelApi::Utils.find_class(obj, opts)
        ModelApi::Renderer.render(self, obj, opts.merge(status: response_status,
            root: ModelApi::Utils.model_name(klass).singular, messages: errs_or_msgs))
      end
      
      def common_response_links(_opts = {})
        {}
      end
      
      def initialize_options(opts)
        opts = opts.symbolize_keys
        opts[:model_class] = model_class
        opts[:user] = user = filter_by_user
        opts[:user_id] = user.try(:id)
        opts[:admin] = user.try(:admin_api_user?) ? true : false
        opts[:admin_content] = admin_content?
        opts[:collection_link_options] = opts[:object_link_options] =
            request.params.to_h.symbolize_keys
        opts
      end
      
      # Default implementation, can be hidden by API controller classes to include any
      # application-specific options
      def prepare_options(opts)
        initialize_options(opts)
      end
      
      def id_info(opts = {})
        id_info = {}
        id_info[:id_attribute] = (opts[:id_attribute] || :id).to_sym
        id_info[:id_param] = (opts[:id_param] || :id).to_sym
        id_info[:id_value] = (opts[:id_value] || params[id_info[:id_param]]).to_s
        id_info
      end
      
      def api_query(opts = {})
        klass = opts[:model_class] || model_class
        unless klass < ActiveRecord::Base
          fail 'Expected model class to be an ActiveRecord::Base subclass'
        end
        query = klass.all
        if (deleted_col = klass.columns_hash['deleted']).present?
          case deleted_col.type
          when :boolean
            query = query.where(deleted: false)
          when :integer, :decimal
            query = query.where(deleted: 0)
          end
        end
        Utils.apply_context(query, opts)
      end
      
      def common_object_query(opts = {})
        klass = opts[:model_class] || model_class
        coll_query = Utils.apply_context(api_query(opts), opts)
        id_info = opts[:id_info] || id_info(opts)
        query = coll_query.where(id_info[:id_attribute] => id_info[:id_value])
        if !admin_access?
          unless opts.include?(:user_filter) && !opts[:user_filter]
            query = user_query(query, opts.merge(model_class: klass))
          end
        elsif id_info[:id_attribute] != :id && !id_info[:id_attribute].to_s.ends_with?('.id') &&
            klass.column_names.include?('id') && !query.exists?
          # Admins can optionally use record ID's if the ID field happens to be something else
          query = coll_query.where(id: id_info[:id_value])
        end
        unless (not_found_error = opts[:not_found_error]).blank? || query.exists?
          not_found_error = not_found_error.call(params[:id]) if not_found_error.respond_to?(:call)
          if not_found_error == true
            not_found_error = "#{klass.model_name.human} '#{id_info[:id_value]}' not found."
          end
          fail ModelApi::NotFoundException.new(id_info[:id_param], not_found_error.to_s)
        end
        query
      end
      
      def collection_query(opts = {})
        opts = base_api_options.merge(opts)
        klass = opts[:model_class] || model_class
        query = api_query(opts)
        unless (opts.include?(:user_filter) && !opts[:user_filter]) ||
            (admin_access? && (admin_content? || filtered_by_foreign_key?(query)))
          query = user_query(query, opts.merge(model_class: klass))
        end
        query
      end
      
      def object_query(opts = {})
        common_object_query(base_api_options.merge(opts))
      end
      
      def user_query(query, opts = {})
        user = opts[:user] || filter_by_user
        klass = opts[:model_class] || model_class
        user_id_col = opts[:user_id_column] || :user_id
        user_assoc = opts[:user_association] || :user
        user_id = user.try(opts[:user_id_attribute] || :id)
        if klass.columns_hash.include?(user_id_col.to_s)
          query = query.where(user_id_col => user_id)
        elsif (assoc = klass.reflect_on_association(user_assoc)).present? &&
            [:belongs_to, :has_one].include?(assoc.macro)
          query = query.joins(user_assoc).where(
              "#{assoc.klass.table_name}.#{assoc.klass.primary_key}" => user_id)
        elsif opts[:user_filter]
          fail "Unable to filter results by user; no '#{user_id_col}' column or " \
                "'#{user_assoc}' association found!"
        end
        query
      end
      
      def base_api_options
        self.class.base_api_options
      end
      
      def base_admin_api_options
        base_api_options.merge(admin_only: true)
      end
      
      def ensure_admin
        user = current_user
        return true if user.respond_to?(:admin_api_user?) && user.admin_api_user?
        
        # Mask presence of endpoint if user is not authorized to access it
        not_found
        false
      end
      
      def unhandled_exception(err)
        return if handle_api_exceptions(err)
        return if performed?
        error_details = {}
        if Rails.env == 'development'
          error_details[:message] = "Exception: #{err.message}"
          error_details[:backtrace] = err.backtrace
        else
          error_details[:message] = 'An internal server error has occurred ' \
              'while processing your request.'
        end
        ModelApi::Renderer.render(self, error_details, root: :error_details,
            status: :internal_server_error)
      end
      
      def handle_api_exceptions(err)
        if err.is_a?(ModelApi::NotFoundException)
          not_found(field: err.field, message: err.message)
        elsif err.is_a?(ModelApi::UnauthorizedException)
          unauthorized
        else
          return false
        end
        true
      end
      
      def doorkeeper_unauthorized_render_options(error: nil)
        { json: unauthorized(error: 'Not authorized to access resource', message: error.description,
            format: :json, generate_body_only: true) }
      end
      
      # Indicates whether user has access to data they do not own.
      def admin_access?
        false
      end
      
      # Indicates whether API should render administrator-only content in API responses
      def admin_content?
        param = request.params[:admin]
        param.present? && param.to_i != 0 && admin_access?
      end
      
      def resource_parent_id(parent_model_class, opts = {})
        id_info = id_info(opts.reverse_merge(id_param: "#{parent_model_class.name.underscore}_id"))
        model_name = parent_model_class.model_name.human
        if id_info[:id_value].blank?
          unless opts[:optional]
            fail ModelApi::NotFoundException.new(id_info[:id_param], "#{model_name} not found")
          end
          return nil
        end
        query = common_object_query(opts.merge(model_class: parent_model_class, id_info: id_info))
        parent_id = query.pluck(:id).first
        if parent_id.blank?
          unless opts[:optional]
            fail ModelApi::NotFoundException.new(id_info[:id_param],
                "#{model_name} '#{id_info[:id_value]}' not found")
          end
          return nil
        end
        parent_id
      end
      
      def simple_error(status, error, opts = {})
        opts = opts.dup
        klass = opts[:class]
        opts[:root] = ModelApi::Utils.model_name(klass).singular if klass.present?
        if error.is_a?(Array)
          errs_or_msgs = error.map do |e|
            if e.is_a?(Hash)
              next e if e.include?(:error) && e.include?(:message)
              next e.reverse_merge(
                  error: e[:error] || 'Unspecified error',
                  message: e[:message] || e[:error] || 'Unspecified error')
            end
            { error: e.to_s, message: e.to_s }
          end
        elsif error.is_a?(Hash)
          errs_or_msgs = [error]
        else
          errs_or_msgs = [{ error: error, message: opts[:message] || error }]
        end
        errs_or_msgs[0][:field] = opts[:field] if opts.include?(:field)
        ModelApi::Renderer.render(self, opts[:request_obj], opts.merge(status: status,
            messages: errs_or_msgs))
      end
      
      def not_found(opts = {})
        opts = opts.dup
        opts[:message] ||= 'No resource found at the path provided or matching the criteria ' \
            'specified'
        simple_error(:not_found, opts.delete(:error) || 'No resource found', opts)
      end
      
      def bad_payload(opts = {})
        opts = opts.dup
        format = opts[:format] || identify_format
        opts[:message] ||= "A properly-formatted #{format.to_s.upcase} " \
            'payload was expected in the HTTP request body but not found'
        simple_error(:bad_request, opts.delete(:error) || 'Missing/invalid request body (payload)',
            opts)
      end
      
      def bad_request(error, message, opts = {})
        opts[:message] = message || 'This request is invalid for the resource in its present state'
        simple_error(:bad_request, error || 'Invalid API request', opts)
      end
      
      def unauthorized(opts = {})
        opts = opts.dup
        opts[:message] ||= 'Missing one or more privileges required to complete request'
        simple_error(:unauthorized, opts.delete(:error) || 'Not authorized', opts)
      end
      
      def not_implemented(opts = {})
        opts = opts.dup
        opts[:message] ||= 'This API feature is presently unavailable'
        simple_error(:not_implemented, opts.delete(:error) || 'Not implemented', opts)
      end
      
      def validate_read_operation(obj, operation, opts = {})
        status, errors = ModelApi::Utils.validate_operation(obj, operation,
            opts.merge(model_metadata: opts[:api_model_metadata] || opts[:model_metadata]))
        return true if status.nil? && errors.nil?
        if errors.nil? && (status.is_a?(Array) || status.present?)
          return true if (errors = status).blank?
          status = :bad_request
        end
        return true unless errors.present?
        errors = [errors] unless errors.is_a?(Array)
        simple_error(status, errors, opts)
        false
      end
      
      def filter_by_user
        current_user
      end
      
      def current_user
        nil
      end
      
      def common_headers
        ModelApi::Utils.common_http_headers.each do |k, v|
          response.headers[k] = v
        end
      end
      
      def identify_format
        format = self.request.format.symbol rescue :json
        format == :xml ? :xml : :json
      end
      
      def ensure_admin_if_admin_only(opts = {})
        return true unless opts[:admin_only]
        ensure_admin
      end
      
      def get_operation(default_operation, opts = {})
        if opts.key?(:operation)
          return opts[:operation]
        elsif action_name.start_with?('create')
          return :create
        elsif action_name.start_with?('update')
          return :update
        elsif action_name.start_with?('patch')
          return :patch
        elsif action_name.start_with?('destroy')
          return :destroy
        else
          return default_operation
        end
      end
      
      def get_updated_object(obj_or_class, operation, opts = {})
        opts = opts.symbolize_keys
        opts[:operation] = operation
        req_body, format = ModelApi::Utils.parse_request_body(request)
        if obj_or_class.is_a?(Class)
          klass = Utils.class_or_sti_subclass(obj_or_class, req_body, operation, opts)
          obj = nil
        elsif obj_or_class.is_a?(ActiveRecord::Base)
          obj = obj_or_class
          klass = obj.class
        elsif obj_or_class.is_a?(ActiveRecord::Relation)
          klass = obj_or_class.klass
          obj = obj_or_class.first
        end
        opts[:api_attr_metadata] = ModelApi::Utils.filtered_attrs(klass, operation, opts)
        opts[:api_model_metadata] = model_metadata = ModelApi::Utils.model_metadata(klass)
        opts[:ignored_fields] = []
        return [nil, opts.merge(bad_payload: true)] if req_body.nil?
        obj = klass.new if obj.nil?
        add_hateoas_links_for_update(opts)
        verify_update_request_body(req_body, format, opts)
        root_elem = opts[:root] = ModelApi::Utils.model_name(klass).singular
        request_obj = opts[:request_obj] = Utils.object_from_req_body(root_elem, req_body, format)
        ModelApi::Utils.apply_updates(obj, request_obj, operation, opts)
        opts.freeze
        ModelApi::Utils.invoke_callback(model_metadata[:after_initialize], obj, opts)
        [obj, opts]
      end
      
      private
      
      def find_filter_params
        request.params.reject { |p, _v| %w(access_token sort_by admin).include?(p) }
      end
      
      def find_sort_params
        sort_by = params[:sort_by]
        return {} if sort_by.blank?
        sort_by = sort_by.to_s.strip
        if sort_by.starts_with?('{') || sort_by.starts_with?('[')
          process_json_sort_params(sort_by)
        else
          process_simple_sort_params(sort_by)
        end
      end
      
      def process_json_sort_params(sort_by)
        sort_params = {}
        sort_json_obj = (JSON.parse(sort_by) rescue {})
        sort_json_obj = Hash[sort_json_obj.map { |v| [v, nil] }] if sort_json_obj.is_a?(Array)
        sort_json_obj.each do |key, value|
          next if key.blank?
          value_lc = value.to_s.downcase
          if %w(a asc ascending).include?(value_lc)
            order = :asc
          elsif %w(d desc descending).include?(value_lc)
            order = :desc
          else
            order = :default
          end
          sort_params[key] = order
        end
        sort_params
      end
      
      def process_simple_sort_params(sort_by)
        sort_params = {}
        sort_by.split(',').each do |key|
          key = key.to_s.strip
          key_lc = key.downcase
          if key_lc.ends_with?('_a') || key_lc.ends_with?(' a')
            key = sort_by[key[0..-3]]
            order = :asc
          elsif key_lc.ends_with?('_asc') || key_lc.ends_with?(' asc')
            key = sort_by[key[0..-5]]
            order = :asc
          elsif key_lc.ends_with?('_ascending') || key_lc.ends_with?(' ascending')
            key = sort_by[key[0..-11]]
            order = :asc
          elsif key_lc.ends_with?('_d') || key_lc.ends_with?(' d')
            key = sort_by[key[0..-3]]
            order = :desc
          elsif key_lc.ends_with?('_desc') || key_lc.ends_with?(' desc')
            key = sort_by[key[0..-6]]
            order = :desc
          elsif key_lc.ends_with?('_descending') || key_lc.ends_with?(' descending')
            key = sort_by[key[0..-12]]
            order = :desc
          else
            order = :default
          end
          next if key.blank?
          sort_params[key] = order
        end
        sort_params
      end
      
      def filter_collection(collection, filter_params, opts = {})
        return [collection, {}] if filter_params.blank? # Don't filter if no filter params
        klass = opts[:class] || ModelApi::Utils.find_class(collection, opts)
        assoc_values, metadata, attr_values = process_filter_params(filter_params, klass, opts)
        result_filters = {}
        metadata.values.each do |attr_metadata|
          collection = apply_filter_param(attr_metadata, collection,
              opts.merge(attr_values: attr_values, result_filters: result_filters, class: klass))
        end
        assoc_values.each do |assoc, assoc_filter_params|
          ar_assoc = klass.reflect_on_association(assoc)
          next unless ar_assoc.present?
          collection = collection.joins(assoc) unless collection.joins_values.include?(assoc)
          collection, assoc_result_filters = filter_collection(collection, assoc_filter_params,
              opts.merge(class: ar_assoc.klass, filter_table: ar_assoc.table_name))
          result_filters[assoc] = assoc_result_filters if assoc_result_filters.present?
        end
        [collection, result_filters]
      end
      
      def process_filter_params(filter_params, klass, opts = {})
        assoc_values = {}
        filter_metadata = {}
        attr_values = {}
        metadata = ModelApi::Utils.filtered_ext_attrs(klass, :filter, opts)
        filter_params.each do |attr, value|
          attr = attr.to_s
          if attr.length > 1 && ['>', '<', '!', '='].include?(attr[-1])
            value = "#{attr[-1]}=#{value}" # Effectively allows >= / <= / != / == in query string
            attr = attr[0..-2].strip
          end
          if attr.include?('.')
            process_filter_assoc_param(attr, metadata, assoc_values, value, opts)
          else
            process_filter_attr_param(attr, metadata, filter_metadata, attr_values, value, opts)
          end
        end
        [assoc_values, filter_metadata, attr_values]
      end
      
      # rubocop:disable Metrics/ParameterLists
      def process_filter_assoc_param(attr, metadata, assoc_values, value, opts)
        attr_elems = attr.split('.')
        assoc_name = attr_elems[0].strip.to_sym
        assoc_metadata = metadata[assoc_name] ||
            metadata[ModelApi::Utils.ext_query_attr(assoc_name, opts)] || {}
        key = assoc_metadata[:key]
        return unless key.present? && ModelApi::Utils.eval_bool(assoc_metadata[:filter], opts)
        assoc_filter_params = (assoc_values[key] ||= {})
        assoc_filter_params[attr_elems[1..-1].join('.')] = value
      end
      
      def process_filter_attr_param(attr, metadata, filter_metadata, attr_values, value, opts)
        attr = attr.strip.to_sym
        attr_metadata = metadata[attr] ||
            metadata[ModelApi::Utils.ext_query_attr(attr, opts)] || {}
        key = attr_metadata[:key]
        return unless key.present? && ModelApi::Utils.eval_bool(attr_metadata[:filter], opts)
        filter_metadata[key] = attr_metadata
        attr_values[key] = value
      end
      
      # rubocop:enable Metrics/ParameterLists
      
      def apply_filter_param(attr_metadata, collection, opts = {})
        raw_value = (opts[:attr_values] || params)[attr_metadata[:key]]
        filter_table = opts[:filter_table]
        klass = opts[:class] || ModelApi::Utils.find_class(collection, opts)
        if raw_value.is_a?(Hash) && raw_value.include?('0')
          operator_value_pairs = filter_process_param_array(params_array(raw_value), attr_metadata,
              opts)
        else
          operator_value_pairs = filter_process_param(raw_value, attr_metadata, opts)
        end
        if (column = resolve_key_to_column(klass, attr_metadata)).present?
          operator_value_pairs.each do |operator, value|
            if operator == '=' && filter_table.blank?
              collection = collection.where(column => value)
            else
              table_name = (filter_table || klass.table_name).to_s.delete('`')
              column = column.to_s.delete('`')
              if value.is_a?(Array)
                operator = 'IN'
                value = value.map { |_v| format_value_for_query(column, value, klass) }
                value = "(#{value.map { |v| "'#{v.to_s.gsub("'", "''")}'" }.join(',')})"
              else
                value = "'#{value.gsub("'", "''")}'"
              end
              collection = collection.where("`#{table_name}`.`#{column}` #{operator} #{value}")
            end
          end
        elsif (key = attr_metadata[:key]).present?
          opts[:result_filters][key] = operator_value_pairs if opts.include?(:result_filters)
        end
        collection
      end
      
      def sort_collection(collection, sort_params, opts = {})
        return [collection, {}] if sort_params.blank? # Don't filter if no filter params
        klass = opts[:class] || ModelApi::Utils.find_class(collection, opts)
        assoc_sorts, attr_sorts, result_sorts = process_sort_params(sort_params, klass,
            opts.merge(result_sorts: result_sorts))
        sort_table = opts[:sort_table]
        sort_table = sort_table.to_s.delete('`') if sort_table.present?
        attr_sorts.each do |key, sort_order|
          if sort_table.present?
            collection = collection.order("`#{sort_table}`.`#{key.to_s.delete('`')}` " \
                "#{sort_order.to_s.upcase}")
          else
            collection = collection.order(key => sort_order)
          end
        end
        assoc_sorts.each do |assoc, assoc_sort_params|
          ar_assoc = klass.reflect_on_association(assoc)
          next unless ar_assoc.present?
          collection = collection.joins(assoc) unless collection.joins_values.include?(assoc)
          collection, assoc_result_sorts = sort_collection(collection, assoc_sort_params,
              opts.merge(class: ar_assoc.klass, sort_table: ar_assoc.table_name))
          result_sorts[assoc] = assoc_result_sorts if assoc_result_sorts.present?
        end
        [collection, result_sorts]
      end
      
      def process_sort_params(sort_params, klass, opts)
        metadata = ModelApi::Utils.filtered_ext_attrs(klass, :sort, opts)
        assoc_sorts = {}
        attr_sorts = {}
        result_sorts = {}
        sort_params.each do |attr, sort_order|
          if attr.include?('.')
            process_sort_param_assoc(attr, metadata, sort_order, assoc_sorts, opts)
          else
            attr = attr.strip.to_sym
            attr_metadata = metadata[attr] || {}
            next unless ModelApi::Utils.eval_bool(attr_metadata[:sort], opts)
            sort_order = sort_order.to_sym
            sort_order = :default unless [:asc, :desc].include?(sort_order)
            if sort_order == :default
              sort_order = (attr_metadata[:default_sort_order] || :asc).to_sym
              sort_order = :asc unless [:asc, :desc].include?(sort_order)
            end
            if (column = resolve_key_to_column(klass, attr_metadata)).present?
              attr_sorts[column] = sort_order
            elsif (key = attr_metadata[:key]).present?
              result_sorts[key] = sort_order
            end
          end
        end
        [assoc_sorts, attr_sorts, result_sorts]
      end
      
      # Intentionally disabling parameter list length check for private / internal method
      # rubocop:disable Metrics/ParameterLists
      def process_sort_param_assoc(attr, metadata, sort_order, assoc_sorts, opts)
        attr_elems = attr.split('.')
        assoc_name = attr_elems[0].strip.to_sym
        assoc_metadata = metadata[assoc_name] || {}
        key = assoc_metadata[:key]
        return unless key.present? && ModelApi::Utils.eval_bool(assoc_metadata[:sort], opts)
        assoc_sort_params = (assoc_sorts[key] ||= {})
        assoc_sort_params[attr_elems[1..-1].join('.')] = sort_order
      end
      
      # rubocop:enable Metrics/ParameterLists
      
      def filter_process_param(raw_value, attr_metadata, opts)
        raw_value = raw_value.to_s.strip
        array = nil
        if raw_value.starts_with?('[') && raw_value.ends_with?(']')
          array = JSON.parse(raw_value) rescue nil
          array = array.is_a?(Array) ? array.map(&:to_s) : nil
        end
        if array.nil?
          if attr_metadata.include?(:filter_delimiter)
            delimiter = attr_metadata[:filter_delimiter]
          else
            delimiter = ','
          end
          array = raw_value.split(delimiter) if raw_value.include?(delimiter)
        end
        return filter_process_param_array(array, attr_metadata, opts) unless array.nil?
        operator, value = parse_filter_operator(raw_value)
        [[operator, ModelApi::Utils.transform_value(value, attr_metadata[:parse], opts)]]
      end
      
      def filter_process_param_array(array, attr_metadata, opts)
        operator_value_pairs = []
        equals_values = []
        array.map(&:strip).reject(&:blank?).each do |value|
          operator, value = parse_filter_operator(value)
          value = ModelApi::Utils.transform_value(value.to_s, attr_metadata[:parse], opts)
          if operator == '='
            equals_values << value
          else
            operator_value_pairs << [operator, value]
          end
        end
        operator_value_pairs << ['=', equals_values.uniq] if equals_values.present?
        operator_value_pairs
      end
      
      def parse_filter_operator(value)
        value = value.to_s.strip
        if (operator = value.scan(/\A(>=|<=|!=|<>)[[:space:]]*\w/).flatten.first).present?
          return (operator == '<>' ? '!=' : operator), value[2..-1].strip
        elsif (operator = value.scan(/\A(>|<|=)[[:space:]]*\w/).flatten.first).present?
          return operator, value[1..-1].strip
        end
        ['=', value]
      end
      
      def format_value_for_query(column, value, klass)
        return value.map { |v| format_value_for_query(column, v, klass) } if value.is_a?(Array)
        column_metadata = klass.columns_hash[column.to_s]
        case column_metadata.try(:type)
        when :date, :datetime, :time, :timestamp
          user = current_user
          if user.respond_to?(:time_zone) && (user_time_zone = user.time_zone).present?
            time_zone = ActiveSupport::TimeZone.new(user_time_zone)
          end
          time_zone ||= ActiveSupport::TimeZone.new('Eastern Time (US & Canada)')
          return time_zone.parse(value.to_s).try(:to_s, :db)
        when :float, :decimal
          return value.to_d.to_s
        when :integer, :primary_key
          return value.to_d.to_s.sub(/\.0\Z/, '')
        when :boolean
          return value ? 'true' : 'false'
        end
        value.to_s
      end
      
      def params_array(raw_value)
        index = 0
        array = []
        while raw_value.include?(index.to_s)
          array << raw_value[index.to_s]
          index += 1
        end
        array
      end
      
      def paginate_collection(collection, collection_links, opts, coll_route)
        collection_size = collection.count
        page_size = (params[:page_size] || DEFAULT_PAGE_SIZE).to_i
        page = [params[:page].to_i, 1].max
        page_count = [(collection_size + page_size - 1) / page_size, 1].max
        page = page_count if page > page_count
        offset = (page - 1) * page_size
        
        opts = opts.dup
        opts[:count] ||= collection_size
        opts[:page] ||= page
        opts[:page_size] ||= page_size
        opts[:page_count] ||= page_count
        
        response.headers['X-Total-Count'] = collection_size.to_s
        
        opts[:collection_link_options] = (opts[:collection_link_options] || {})
            .reject { |k, _v| [:page].include?(k.to_sym) }
        opts[:object_link_options] = (opts[:object_link_options] || {})
            .reject { |k, _v| [:page, :page_size].include?(k.to_sym) }
        
        if collection_size > page_size
          opts[:collection_link_options][:page] = page
          Utils.add_pagination_links(collection_links, coll_route, page, page_count)
          collection = collection.limit(page_size).offset(offset)
        end
        
        [collection, collection_links, opts]
      end
      
      def resolve_key_to_column(klass, attr_metadata)
        return nil unless klass.respond_to?(:columns_hash)
        columns_hash = klass.columns_hash
        key = attr_metadata[:key]
        return key if columns_hash.include?(key.to_s)
        render_method = attr_metadata[:render_method]
        render_method = render_method.to_s if render_method.is_a?(Symbol)
        return nil unless render_method.is_a?(String)
        columns_hash.include?(render_method) ? render_method : nil
      end
      
      def add_collection_object_route(opts)
        object_route = opts[:object_route]
        unless object_route.present?
          route_name = ModelApi::Utils.route_name(request)
          if route_name.present?
            if (singular_route_name = route_name.singularize) != route_name
              object_route = singular_route_name
            end
          end
        end
        if object_route.present? && (object_route.is_a?(String) || object_route.is_a?(Symbol))
          object_route = nil unless self.respond_to?("#{object_route}_url")
        end
        object_route = opts[:default_object_route] if object_route.blank?
        return if object_route.blank?
        opts[:object_links] = (opts[:object_links] || {}).merge(self: object_route)
      end
      
      def add_hateoas_links_for_update(opts)
        object_route = opts[:object_route] || self
        links = { self: object_route }.reverse_merge(common_response_links(opts))
        opts[:links] = links.merge(opts[:links] || {})
      end
      
      def add_hateoas_links_for_updated_object(_operation, opts)
        object_route = opts[:object_route] || self
        object_links = { self: object_route }
        opts[:object_links] = object_links.merge(opts[:object_links] || {})
      end
      
      def verify_update_request_body(request_body, format, opts = {})
        if request.format.symbol.nil? && format.present?
          opts[:format] ||= format
        end
        
        if request_body.is_a?(Array)
          fail 'Expected object, but collection provided'
        elsif !request_body.is_a?(Hash)
          fail 'Expected object'
        end
      end
      
      def filtered_by_foreign_key?(query)
        fk_cache = self.class.instance_variable_get(:@foreign_key_cache)
        self.class.instance_variable_set(:@foreign_key_cache, fk_cache = {}) if fk_cache.nil?
        klass = query.klass
        foreign_keys = (fk_cache[klass] ||= query.klass.reflections.values
            .select { |a| a.macro == :belongs_to }.map { |a| a.foreign_key.to_s })
        (query.values[:where] || []).select { |v| v.is_a?(Arel::Nodes::Equality) }
            .map { |v| v.left.name }.each do |key|
          return true if foreign_keys.include?(key)
        end
        false
      rescue Exception => e
        Rails.logger.warn "Exception encounterd determining if query is filtered: #{e.message}\n" \
            "#{e.backtrace.join("\n")}"
      end
    end
    
    class Utils
      class << self
        def add_pagination_links(collection_links, coll_route, page, last_page)
          if page < last_page
            collection_links[:next] = [coll_route, { page: (page + 1) }]
          end
          collection_links[:prev] = [coll_route, { page: (page - 1) }] if page > 1
          collection_links[:first] = [coll_route, { page: 1 }]
          collection_links[:last] = [coll_route, { page: last_page }]
        end
        
        def object_from_req_body(root_elem, req_body, format)
          if format == :json
            request_obj = req_body
          else
            request_obj = req_body[root_elem]
            if request_obj.blank?
              request_obj = req_body['obj']
              if request_obj.blank? && req_body.size == 1
                request_obj = req_body.values.first
              end
            end
          end
          fail 'Invalid request format' unless request_obj.present?
          request_obj
        end
        
        def process_updated_model_save(obj, operation, opts = {})
          opts = opts.dup
          opts[:operation] = operation
          successful = ModelApi::Utils.save_obj(obj,
              opts.merge(model_metadata: opts[:api_model_metadata]))
          if successful
            suggested_response_status = :ok
            object_errors = []
          else
            suggested_response_status = :bad_request
            attr_metadata = opts.delete(:api_attr_metadata) ||
                ModelApi::Utils.filtered_attrs(obj, operation, opts)
            object_errors = ModelApi::Utils.extract_error_msgs(obj,
                opts.merge(api_attr_metadata: attr_metadata))
            unless object_errors.present?
              object_errors << {
                  error: 'Unspecified error',
                  message: "Unspecified error processing #{operation}: " \
                      'Please contact customer service for further assistance.'
              }
            end
          end
          [suggested_response_status, object_errors]
        end
        
        def process_object_destroy(obj, operation, opts)
          soft_delete = obj.errors.present? ? false : object_destroy(obj, opts)
          
          if obj.errors.blank? && (soft_delete || obj.destroyed?)
            response_status = :ok
            object_errors = []
          else
            object_errors = ModelApi::Utils.extract_error_msgs(obj, opts)
            if object_errors.present?
              response_status = :bad_request
            else
              response_status = :internal_server_error
              object_errors << {
                  error: 'Unspecified error',
                  message: "Unspecified error processing #{operation}: " \
                      'Please contact customer service for further assistance.'
              }
            end
          end
          
          [response_status, object_errors]
        end
        
        def object_destroy(obj, opts = {})
          klass = ModelApi::Utils.find_class(obj)
          object_id = obj.send(opts[:id_attribute] || :id)
          obj.instance_variable_set(:@readonly, false) if obj.instance_variable_get(:@readonly)
          if (deleted_col = klass.columns_hash['deleted']).present?
            case deleted_col.type
            when :boolean
              obj.update_attribute(:deleted, true)
              return true
            when :integer, :decimal
              obj.update_attribute(:deleted, 1)
              return true
            else
              obj.destroy
            end
          else
            obj.destroy
          end
          false
        rescue Exception => e
          Rails.logger.warn "Error destroying #{klass.name} \"#{object_id}\": \"#{e.message}\")."
          false
        end
        
        def apply_context(query, opts = {})
          context = opts[:context]
          return query if context.nil?
          if context.respond_to?(:call)
            query = context.send(*([:call, query, opts][0..context.parameters.size]))
          elsif context.is_a?(Hash)
            context.each { |attr, value| query = query.where(attr => value) }
          end
          query
        end
        
        def class_or_sti_subclass(klass, req_body, operation, opts = {})
          metadata = ModelApi::Utils.filtered_attrs(klass, :create, opts)
          if operation == :create && (attr_metadata = metadata[:type]).is_a?(Hash) &&
              req_body.is_a?(Hash)
            external_attr = ModelApi::Utils.ext_attr(:type, attr_metadata)
            type = req_body[external_attr.to_s]
            begin
              type = ModelApi::Utils.transform_value(type, attr_metadata[:parse], opts.dup)
            rescue Exception => e
              Rails.logger.warn 'Error encountered parsing API input for attribute ' \
                  "\"#{external_attr}\" (\"#{e.message}\"): \"#{type.to_s.first(1000)}\" ... " \
                  'using raw value instead.'
            end
            if type.present? && (type = type.camelize) != klass.name
              Rails.application.eager_load!
              klass.subclasses.each do |subclass|
                return subclass if subclass.name == type
              end
            end
          end
          klass
        end
      end
    end
  end
end
