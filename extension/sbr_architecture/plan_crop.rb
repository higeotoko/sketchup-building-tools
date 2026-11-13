# frozen_string_literal: true

module Higeotoko
  module SbrArchitecture
    module PlanCrop
      MIN_SPAN = 1.0
      module_function

      def rectangle(first, last)
        x_min, x_max = [first[0], last[0]].minmax
        y_min, y_max = [first[1], last[1]].minmax
        [x_min, y_min, x_max, y_max]
      end

      def extent(crop)
        [crop[2] - crop[0], crop[3] - crop[1]]
      end

      def settings(input, named:)
        values = input['plan_crop']
        return {} if values.nil?
        raise ArgumentError, '部分範囲は名前付き平面に登録してください。' unless named
        unless values.is_a?(Array) && values.length == 4
          raise ArgumentError, '平面の範囲を指定し直してください。'
        end

        first, last = values.map { |value| Layout.mm(value, '平面の範囲') }.each_slice(2).to_a
        crop = rectangle(first, last)
        unless extent(crop).all? { |span| span.finite? && span >= MIN_SPAN }
          raise ArgumentError, '平面の範囲は幅・奥行きともに1 mm以上にしてください。'
        end

        { 'plan_crop' => crop }
      end

      def box(crop, base)
        result = Geom::BoundingBox.new
        result.add(SbrArchitecture.point(*crop.first(2), base.min.z.to_mm),
                   SbrArchitecture.point(*crop.last(2), base.max.z.to_mm))
        result
      end
    end
  end
end
