# frozen_string_literal: true

module Higeotoko
  module SbrArchitecture
    module PlanRange
      API = SbrArchitecture
      DASH_MM = 3.0
      GAP_MM = 1.5
      MIN_DASH_MM = 0.25
      module_function

      def settings(input, cut)
        bottom = Layout.mm(input['plan_bottom'], '表示下限') unless input['plan_bottom'].to_s.strip.empty?
        top = Layout.mm(input['plan_top'], '頭上梁の表示上限') unless input['plan_top'].to_s.strip.empty?
        raise ArgumentError, '表示下限は切断高さより低くしてください。' if bottom && bottom >= cut
        raise ArgumentError, '頭上梁の表示上限は切断高さより高くしてください。' if top && top <= cut

        { 'plan_bottom' => bottom, 'plan_top' => top }.compact
      end

      def outside?(group, bottom, cut)
        box = group.bounds
        Follow.kind(group) == 'stair' || !box.valid? || box.max.z.to_mm < bottom || box.min.z.to_mm >= cut
      end

      def overhead_beams(groups, cut, top, hidden)
        groups.select do |group|
          next unless Follow.kind(group) == 'beam' && !hidden.include?(group.persistent_id) && group.layer.visible?

          box = group.bounds
          box.valid? && box.min.z.to_mm.between?(cut, top)
        end
      end

      def dash_spans(a, b, denominator)
        dx = b[0] - a[0]
        dy = b[1] - a[1]
        length = Math.hypot(dx, dy)
        spans = []
        start = 0.0
        while start + MIN_DASH_MM * denominator <= length
          finish = [start + DASH_MM * denominator, length].min
          spans << [start, finish].map { |distance| [a[0] + dx * distance / length, a[1] + dy * distance / length] }
          start += (DASH_MM + GAP_MM) * denominator
        end
        spans
      end

      def draw_overhead(group, beams, cut, denominator, masks)
        entities = group.entities
        beams.count do |beam|
          outline = FramingPlan.footprint(beam, Follow.parameters(beam))
          next false if outline.size < 3

          edges = outline.zip(outline.rotate).flat_map do |a, b|
            dash_spans(a, b, denominator).flat_map do |first, last|
              ColumnCuts.clip(first, last, masks).filter_map do |start, finish|
                next if Math.hypot(finish[0] - start[0], finish[1] - start[1]) < MIN_DASH_MM * denominator

                entities.add_line(API.point(*start, cut - 0.2), API.point(*finish, cut - 0.2))
              end
            end
          end
          edges.each { |edge| edge.layer = group.model.layers[0] }
          edges.any?
        end
      end
    end
  end
end
