class BandwidthApi
  include Invoca::Metrics::Source

  PARTIAL_RESULTS_ERROR_CODE = "5017"
  EMPTY_RESULTS_ERROR_CODE   = "5018"

  class ApiError < StandardError
    attr_accessor :http_status_code, :response_body
    def initialize(http_status_code, response_body, message = "")
      @http_status_code, @response_body = http_status_code, response_body
      super(message)
    end

    def to_s
      "#{super}\nhttp status code: #{@http_status_code}\nresponse body: #{@response_body}"
    end
  end


  class << self
    def log_success_or_failure_metric(metric_name)
      begin
        result = yield
        metrics.increment("bandwidth_api.#{metric_name}.success")
        result
      rescue => ex
        metrics.increment("bandwidth_api.#{metric_name}.failure")
        raise ex
      end
    end


    # TODO: Rahul Kapadia make this a meta macro:  add_log_success_or_failure :place_order_for_npa_nxx -Colin
    def availability_for_npa(npa)
      log_success_or_failure_metric("availability_for_npa") do
        availability_for_npa_before_metrics(npa)
      end
    end



    def place_order_for_npa_nxx(npa_nxx, quantity)
      log_success_or_failure_metric("place_order_for_npa_nxx") do
        place_order_for_npa_nxx_before_metrics(npa_nxx, quantity)
      end
    end


    def phone_numbers_for_order(order_id)
      log_success_or_failure_metric("phone_numbers_for_order") do
        phone_numbers_for_order_before_metrics(order_id)
      end
    end

    def order_phone_numbers_for_npa_nxx(npa_nxx, quantity)
      order_id = place_order_for_npa_nxx(npa_nxx, quantity)
      # TODO Rahul Kapadia make this smarter to retry multiple times
      sleep(ORDER_CREATION_DELAY_SECONDS) # pause for order to be created on the Bandwidth side so we can ask about it
      phone_numbers_for_order(order_id)
    end

    def remote_procedure(method, verb: :get, body: "", query: {})
      query_string = query.to_query unless query.empty?
      path = ["/v#{version}/accounts/#{account_id}/#{method}", query_string].compact.join('?')
      options = {
        :use_ssl => true,
        :basic_auth => {
          :username => username,
          :password => password
        }
      }
      case verb
      when :get
        HTTPFailover.get_response(host, path, options)
      when :post
        HTTPFailover.xml_post_response(host, path, { "Content-Type" => "application/xml" } , body, options)
      else
        raise "Unexpected verb #{verb}"
      end
    end

    private

    def phone_numbers_for_order_before_metrics(order_id)
      response = remote_procedure("orders/#{order_id}", verb: :get)
      response.code == "200" or raise ApiError.new(response.code, response.body)

      structured_response_body = Hash.from_xml(response.body)
      order_response = process_structured_response(structured_response_body, "OrderResponse", response)

      error_codes = Array.wrap(order_response["ErrorList"]._?["Error"]).map { |error| error["Code"] }
      error_codes.many? and raise ApiError.new(response.code, response.body, "Unexpected multiple error codes")

      case error_code = error_codes.first
        when EMPTY_RESULTS_ERROR_CODE
          []
        when NilClass, PARTIAL_RESULTS_ERROR_CODE
          parse_phone_numbers(order_response, response)
        else
          raise ApiError.new(response.code, response.body, "Unexpected error code")
      end
    end

    def availability_for_npa_before_metrics(npa)
      response = remote_procedure("availableNpaNxx", verb: :get, query: { areaCode: npa })
      case response.code
        when "200"
          structured_response_body = Hash.from_xml(response.body)
          search_result = process_structured_response(structured_response_body, "SearchResultForAvailableNpaNxx", response)
          available_npa_nxx_list = process_structured_response(search_result, "AvailableNpaNxxList", response)
          Array.wrap(available_npa_nxx_list._?["AvailableNpaNxx"]).map do |entry|
            { :nxx => entry["Nxx"], :quantity => entry["Quantity"] }
          end
        when "400"
          exception = ApiError.new(response.code, response.body)
          structured_response_body = Hash.from_xml(response.body)
          search_result = process_structured_response(structured_response_body, "SearchResultForAvailableNpaNxx", response)
          error =  process_structured_response(search_result, "Error", response)
          error_code = process_structured_response(error, "Code", response)
          error_description = process_structured_response(error, "Description", response)
          # implies bandwidth is not familiar with the npa we have provided (lerg mismatch)
          if error_code == "4000" && error_description =~ /not present as a valid entry in our system/
            metrics.increment("bandwidth_api.availability_for_npa.invalid_npa")
            ExceptionHandling.log_error(exception, "The npa '#{npa}' is not present in bandwidth as a valid enty")
            []
          else
            raise exception
          end
        else
          raise ApiError.new(response.code, response.body)
      end
    end

    def place_order_for_npa_nxx_before_metrics(npa_nxx, quantity)
      request_body = {
          :SiteId => site_id,
          :NPANXXSearchAndOrderType => { :NpaNxx => npa_nxx, :Quantity => quantity, :EnableLCA => false }
      }.to_xml(:root => "Order", :skip_types => true)

      response = remote_procedure("orders", verb: :post, body: request_body)

      response.code == "201" or raise ApiError.new(response.code, response.body)
      structured_response_body = Hash.from_xml(response.body)
      order_response = process_structured_response(structured_response_body, "OrderResponse", response)
      order = process_structured_response(order_response, "Order", response)
      id = process_structured_response(order, "id", response)

      id.nonblank? or raise ApiError.new(response.code, response.body, "id of the order is blank")
    end

    def parse_phone_numbers(order_response, response)
      completed_numbers = process_structured_response(order_response, "CompletedNumbers", response)
      telephone_numbers = Array.wrap(process_structured_response(completed_numbers, "TelephoneNumber", response))
      !telephone_numbers.empty? or raise ApiError.new(response.code, response.body, "FullNumber not found in response")

      telephone_numbers.map do |telephone_number|
        phone_number = PhoneNumber.new(process_structured_response(telephone_number, "FullNumber", response))
        (phone_number.valid? && !phone_number.empty?) or raise ApiError.new(response.code, response.body, "Invalid phone number in response")
        phone_number
      end
    end

    def process_structured_response(structured_response, element, response)
      structured_response._?.key?(element) or raise ApiError.new(response.code, response.body, "#{element} not found in response")
      structured_response[element]
    end

    def bandwidth_api_secrets
      Secrets[:bandwidth_api]
    end

    def host
      bandwidth_api_secrets[:host]
    end

    def version
      bandwidth_api_secrets[:version]
    end

    def account_id
      bandwidth_api_secrets[:account_id]
    end

    def username
      bandwidth_api_secrets[:username]
    end

    def password
      bandwidth_api_secrets[:password]
    end

    def site_id
      bandwidth_api_secrets[:site_id]
    end

  end
end
