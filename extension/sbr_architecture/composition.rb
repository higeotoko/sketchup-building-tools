# frozen_string_literal: true

module Higeotoko
  module SbrArchitecture
    module Composition
      API = SbrArchitecture
      PATTERNS = { 'diag' => '斜線 ／', 'reverse' => '斜線 ＼', 'cross' => '交差線', 'level' => '平行線', 'none' => '線なし' }.freeze
      module_function

      def parse(rows)
        unless rows.is_a?(Array) && rows.size <= 12
          raise ArgumentError, '層は12層まで指定できます。'
        end

        rows.each_with_index.map do |row, index|
          name = row['name'].to_s.strip
          raise ArgumentError, "#{index + 1}層目の名前を1〜60文字で入力してください。" if name.empty? || name.length > 60

          pattern = row.fetch('pattern')
          raise ArgumentError, '断面ハッチを選択してください。' unless PATTERNS.key?(pattern)

          { 'name' => name, 'thickness' => Layout.mm(row['thickness'], "#{index + 1}層目の厚さ", positive: true),
            'pattern' => pattern }
        end
      end

      def bands(params)
        entries = params.fetch('layers', [])
        total = entries.sum { |layer| layer.fetch('thickness') }
        raise ArgumentError, '層厚の合計と部材厚が一致しません。' if entries.any? && (total - params.fetch('thickness')).abs > 0.000001

        offset = 0.0
        entries.each_with_index.map do |layer, index|
          start = offset
          offset += layer.fetch('thickness')
          [layer, index, start, offset]
        end
      end

      def layer_group(parent, layer, index)
        group = parent.entities.add_group
        group.name = "#{index + 1}｜#{layer.fetch('name')}"
        group.layer = parent.model.layers[0]
        group.set_attribute(API::DICT, 'composition_index', index)
        group.set_attribute(API::DICT, 'composition_layer', JSON.generate(layer))
        group
      end

      def between(a, b, fraction)
        a.zip(b).map { |left, right| left + (right - left) * fraction }
      end

      def wall_profile(profile, from, to, total)
        a, b, c, d = profile
        left, right = [from, to].map { |value| value / total }
        [between(a, b, left), between(a, b, right), between(d, c, right), between(d, c, left)]
      end

      def slab(group, params)
        outline = Layout.slab_outline(params.fetch('points'))
        holes = SlabOpenings.rings(params, outline)
        layers = bands(params)
        if layers.empty?
          thickness = params.fetch('thickness')
          SlabOpenings.write(group, outline, holes, -thickness, 0)
        else
          layers.each do |layer, index, start, finish|
            SlabOpenings.write(layer_group(group, layer, index), outline, holes, -finish, -start)
          end
        end
      end

      def each_layer(group, transform = group.transformation, &block)
        group.entities.grep(Sketchup::Group).each do |child|
          placement = transform * child.transformation
          raw = child.get_attribute(API::DICT, 'composition_layer')
          if raw
            block.call(child, JSON.parse(raw), child.get_attribute(API::DICT, 'composition_index'), placement)
          else
            each_layer(child, placement, &block)
          end
        end
      end
    end
  end
end
