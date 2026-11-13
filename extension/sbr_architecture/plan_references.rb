# frozen_string_literal: true

require 'json'

module Higeotoko
  module SbrArchitecture
    module PlanReferences
      API = SbrArchitecture
      SIGNATURE = 'partial_plan_references'
      DRAWN_KEYS = 'drawn_partial_plan_keys'
      INK = 'SBT｜部分平面参照'
      module_function

      def settings(input, identity, crop)
        return {} if crop || !input.key?('show_partial_refs')

        value = input['show_partial_refs'] == true
        value == !identity.key?('plan_name') ? {} : { 'show_partial_refs' => value }
      end

      def targets(specs, numbers)
        specs.filter_map do |item|
          next unless item['kind'] == 'plan' && item['plan_crop']

          item.merge('sheet' => Drawings.sheet_label(numbers.fetch(item.fetch('key'))))
        end.sort_by { |item| [numbers.fetch(item.fetch('key')) || Float::INFINITY, item.fetch('key')] }
      end

      def for_plan(data, targets)
        return [] unless data['kind'] == 'plan' && !data['plan_crop'] &&
                         data.fetch('show_partial_refs', !data.key?('plan_name'))

        targets.select { |item| item['level'] == data['level'] && item['key'] != data['key'] }
      end

      def signature(targets)
        rows = targets.map { |item| item.values_at('key', 'sheet', 'plan_name', 'plan_crop') }.sort_by(&:first)
        JSON.generate(rows)
      end

      def stale?(page, data, targets)
        return false unless data['kind'] == 'plan'

        page.get_attribute(Drawings::META, SIGNATURE, '[]') != signature(for_plan(data, targets))
      end

      def label_bounds(crop, label, denominator, masks, obstacles)
        x1, y1, x2, y2 = crop
        gap = 3 * denominator
        width = (label.each_char.sum { |char| char.ascii_only? ? 2.1 : 3.6 } + 5) * denominator
        candidates = [
          [[x2, y2], [x2 - gap, y2 + gap]],
          [[x1, y2], [x1 + gap, y2 + gap]],
          [[x2, y1], [x2 - gap, y1 - gap]],
          [[x1, y1], [x1 + gap, y1 - gap]]
        ]
        candidates.each do |anchor, point|
          mask = label_mask(anchor, point, width, denominator)
          next if masks.any? { |other| FramingPlan.overlaps_label?(mask, other) }
          next if obstacles.any? { |a, b| ColumnCuts.intersects?(a, b, [mask]) }

          return [anchor, point, mask]
        end

        # If every nearby position is occupied, put the reference above the
        # other annotations in this horizontal band.
        anchor = [x2, y2]
        x = x2 - gap
        mask_top = masks.filter_map { |_, xs, ys| ys.last if xs.first < x && x - width < xs.last }.max
        stroke_top = obstacles.filter_map do |a, b|
          low, high = [a[0], b[0]].minmax
          [a[1], b[1]].max if low < x && x - width < high
        end.max
        point = [x, [mask_top, stroke_top, y2].compact.max + gap + 2 * denominator]
        [anchor, point, label_mask(anchor, point, width, denominator)]
      end

      def label_mask(anchor, point, width, denominator)
        x, y = point
        left = x < anchor[0] ? x - width : x
        ColumnCuts.mask_for([rectangle(left, y - 2 * denominator, width, 6.4 * denominator)])
      end

      def rectangle(x, y, width, height)
        [[x, y], [x + width, y], [x + width, y + height], [x, y + height]]
      end

      def draw(group, references, cut, denominator, masks, obstacles: [])
        entities = group.entities
        materials = group.model.materials
        ink = materials[INK] || materials.add(INK)
        color = Sketchup::Color.new(50, 76, 92)
        ink.color = color unless ink.color == color
        z = cut - 0.2
        line = lambda do |a, b|
          edge = entities.add_line(API.point(*a, z), API.point(*b, z))
          edge.material = ink if edge
        end
        used = masks.dup
        placements = references.map do |item|
          label = "#{item.fetch('sheet')}｜#{item.fetch('plan_name')}"
          anchor, point, mask = label_bounds(item.fetch('plan_crop'), label, denominator, used, obstacles)
          used << mask
          [label, anchor, point, mask]
        end
        references.map { |item| item.fetch('plan_crop') }.uniq.each do |x1, y1, x2, y2|
          outline = rectangle(x1, y1, x2 - x1, y2 - y1)
          outline.zip(outline.rotate).each do |a, b|
            spans = PlanRange.dash_spans(a, b, denominator)
            spans = [[a, b]] if spans.empty?
            spans.each do |first, last|
              ColumnCuts.clip(first, last, used).each { |u, v| line.call(u, v) }
            end
          end
        end
        placements.each do |label, anchor, point, _|
          dx, dy = point.zip(anchor).map { |a, b| a - b }
          mark = entities.add_text(label, API.point(*anchor, z), Geom::Vector3d.new(dx.mm, dy.mm, 0))
          raise ArgumentError, '部分平面の参照図番を描けませんでした。' unless mark

          mark.leader_type = ALeaderModel
          mark.arrow_type = Sketchup::Dimension::ARROW_NONE
          mark.font = { size: 9 } if mark.respond_to?(:font=)
        end
        entities.each { |entity| entity.layer = group.model.layers[0] }
        placements.map(&:last)
      end
    end
  end
end
