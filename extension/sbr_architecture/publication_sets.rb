# frozen_string_literal: true

require 'json'
require 'securerandom'

module Higeotoko
  module SbrArchitecture
    module PublicationSets
      API = SbrArchitecture
      KEY = 'publication_sets'
      module_function

      def all(model)
        JSON.parse(model.get_attribute(Drawings::META, KEY, '[]'))
      end

      def find(model, id)
        all(model).find { |item| item.fetch('id') == id } ||
          raise(ArgumentError, '発行セットが見つかりません。図面・シーンを開き直してください。')
      end

      def drawing_subset(scenes, keys)
        return scenes if keys.nil?

        unless keys.is_a?(Array) && keys.any? && keys.all? { |key| key.is_a?(String) } && keys.uniq.size == keys.size
          raise ArgumentError, '発行する図面を1枚以上選んでください。'
        end

        selected = scenes.select { |_, data| keys.include?(data.fetch('key')) }
        if selected.size != keys.size
          raise ArgumentError, '発行セットに削除済みの図面があります。発行セットを編集して保存してください。'
        end

        selected
      end

      def save(model, input)
        name = input.fetch('name', '').to_s.strip
        if name.empty? || name.size > 32 || name.match?(/[[:cntrl:]]/)
          raise ArgumentError, '発行セット名を32文字以内で入力してください。'
        end
        sets = all(model)
        id = input['id'].to_s
        previous = sets.find { |item| item.fetch('id') == id }
        raise ArgumentError, '編集する発行セットが見つかりません。' if !id.empty? && !previous
        if sets.any? { |item| item != previous && item.fetch('name').casecmp?(name) }
          raise ArgumentError, '同じ名前の発行セットがあります。'
        end

        scenes = drawing_subset(Drawings.specs(model), input.fetch('keys', []))
        tables = input.fetch('tables', [])
        unless tables.is_a?(Array) && (tables - DrawingSchedules::TABLES.keys).empty?
          raise ArgumentError, '発行する表の設定を確認してください。'
        end
        arrangement = input.fetch('arrangement', 'single')
        raise ArgumentError, 'LayOutの配置方法を選んでください。' unless LayoutSheets::ARRANGEMENTS.include?(arrangement)

        item = { 'id' => previous ? id : SecureRandom.uuid, 'name' => name,
                 'keys' => scenes.map { |_, data| data.fetch('key') }, 'tables' => tables.uniq, 'arrangement' => arrangement }
        previous ? sets[sets.index(previous)] = item : sets << item
        write(model, sets) unless item == previous
        item
      end

      def remove(model, id)
        item = find(model, id)
        write(model, all(model).reject { |entry| entry.fetch('id') == id })
        item
      end

      def write(model, sets)
        API.operation(model, '発行セットを更新') { model.set_attribute(Drawings::META, KEY, JSON.generate(sets)) }
      end
    end
  end
end
