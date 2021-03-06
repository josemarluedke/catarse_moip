require 'enumerate_it'
require 'moip_transparente'

module CatarseMoip
  class MoipController < ApplicationController
    attr_accessor :backer

    class TransactionStatus < ::EnumerateIt::Base
      associate_values(
        :authorized =>      1,
        :started =>         2,
        :printed_boleto =>  3,
        :finished =>        4,
        :canceled =>        5,
        :process =>         6,
        :written_back =>    7,
        :refunded => 9
      )
    end

    skip_before_filter :force_http
    layout :false

    def create_notification
      @backer = PaymentEngines.find_payment key: params[:id_transacao]
      process_moip_message if @backer.payment_method == 'MoIP' || @backer.payment_method.nil?
      return render :nothing => true, :status => 200
    rescue Exception => e
      return render :text => "#{e.inspect}: #{e.message} recebemos: #{params}", :status => 422
    end

    def js
      tries = 0
      begin
        @moip = ::MoipTransparente::Checkout.new
        render :text => open(@moip.get_javascript_url).set_encoding('ISO-8859-1').read.encode('utf-8')
      rescue Exception => e
        tries += 1
        retry unless tries > 3
        raise e
      end
    end

    def review
      @moip = ::MoipTransparente::Checkout.new
    end

    def moip_response
      @backer = PaymentEngines.find_payment id: params[:id], user_id: current_user.id
      first_update_backer unless params[:response]['StatusPagamento'] == 'Falha'
      render nothing: true, status: 200
    end

    def get_moip_token
      @backer = PaymentEngines.find_payment id: params[:id], user_id: current_user.id

      ::MoipTransparente::Config.test = (PaymentEngines.configuration[:moip_test] == 'true')
      ::MoipTransparente::Config.access_token = PaymentEngines.configuration[:moip_token]
      ::MoipTransparente::Config.access_key = PaymentEngines.configuration[:moip_key]

      @moip = ::MoipTransparente::Checkout.new

      invoice = {
        razao: "Apoio para o projeto '#{backer.project.name}'",
        id: backer.key,
        total: backer.value.to_s,
        acrescimo: '0.00',
        desconto: '0.00',
        cliente: {
          id: backer.user.id,
          nome: backer.payer_name,
          email: backer.payer_email,
          logradouro: "#{backer.address_street}, #{backer.address_number}",
          complemento: backer.address_complement,
          bairro: backer.address_neighbourhood,
          cidade: backer.address_city,
          uf: backer.address_state,
          cep: backer.address_zip_code,
          telefone: backer.address_phone_number
        }
      }

      response = @moip.get_token(invoice)

      session[:thank_you_id] = backer.project.id

      backer.update_column :payment_token, response[:token] if response and response[:token]

      render json: {
        get_token_response: response,
        moip: @moip,
        widget_tag: {
          tag_id: 'MoipWidget',
          token: response[:token],
          callback_success: 'checkoutSuccessful',
          callback_error: 'checkoutFailure'
        }
      }
    end

    def first_update_backer
      response = ::MoIP.query(backer.payment_token)
      if response && response["Autorizacao"]
        params = response["Autorizacao"]["Pagamento"]
        params = params.first unless params.respond_to?(:key)

        backer.with_lock do
          if params["Status"] == "Autorizado"
            backer.confirm!
          elsif backer.pending?
            backer.waiting! 
          end

          backer.update_attributes({
            :payment_id => params["CodigoMoIP"],
            :payment_choice => params["FormaPagamento"],
            :payment_method => 'MoIP',
            :payment_service_fee => params["TaxaMoIP"]
          }) if params
        end
      end
    end

    def process_moip_message
      backer.with_lock do
        PaymentEngines.create_payment_notification backer_id: backer.id, extra_data: JSON.parse(params.to_json.force_encoding('iso-8859-1').encode('utf-8'))
        payment_id = (backer.payment_id.gsub(".", "").to_i rescue 0)

        if payment_id <= params[:cod_moip].to_i
          backer.update_attributes payment_id: params[:cod_moip]

          case params[:status_pagamento].to_i
          when TransactionStatus::AUTHORIZED
            backer.confirm! unless backer.confirmed?
          when TransactionStatus::WRITTEN_BACK, TransactionStatus::REFUNDED
            backer.refund! unless backer.refunded?
          when TransactionStatus::CANCELED
            backer.cancel! unless backer.canceled?
          end
        end
      end
    end
  end
end
