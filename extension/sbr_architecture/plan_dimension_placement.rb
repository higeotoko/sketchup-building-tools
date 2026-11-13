# frozen_string_literal: true

module Higeotoko
  module SbrArchitecture
    class PlanDimensionPlacement
      API = SbrArchitecture
      SNAP_PIXELS = 10

      def initialize(model, page, data, cut, anchors, &finish)
        @model, @page, @crop, @z = model, page, data['plan_crop'], cut
        @anchors, @finish = anchors, finish
        @candidates = anchors.values.flatten
        @refs = []
      end

      def activate
        prompt
      end

      def resume(view)
        prompt
        view.invalidate
      end

      def deactivate(view)
        view.invalidate
        complete(nil)
      end

      def cancel
        @model.select_tool(nil) if @finish
      end

      def onCancel(reason, _view)
        cancel if reason.zero?
      end

      def current?(view)
        @model.pages.selected_page == @page && SectionPlacement.top_view?(view)
      end

      def pick(view, x, y)
        @candidates.filter_map do |anchor|
          a, b = [anchor.a, anchor.b].map { |xy| screen(view, xy) }
          t = PlanDimensions.foot([x, y], a, b).clamp(0, 1)
          u, v = a.zip(b).map { |first, last| first + (last - first) * t }
          distance = Math.hypot(x - u, y - v)
          next if distance > SNAP_PIXELS

          point = anchor.at(t)
          [distance, anchor.reference(t), point] if PlanDimensions.within_crop?([point], @crop)
        end.min_by(&:first)&.drop(1)
      end

      def onMouseMove(_flags, x, y, view)
        @hit = @offset = @preview = nil
        unless current?(view)
          Sketchup.set_status_text('寸法を入れる一般平面に戻るか、Escで終了してください。', SB_PROMPT)
          view.invalidate
          return
        end

        if @refs.size == 2
          cursor = Geom.intersect_line_plane(view.pickray(x, y), [API.point(0, 0, @z), Z_AXIS])
          if cursor
            normal, = PlanDimensions.geometry(@points, 0)
            u, v = PlanDimensions.xy(cursor)
            @offset = ((u - @points[0][0]) * normal[0] + (v - @points[0][1]) * normal[1]).round(2)
            @preview = PlanDimensions.geometry(@points, @offset).last
          end
        else
          @hit = pick(view, x, y)
          if @hit
            view.tooltip = @hit.first.key?('segment') ? '壁仕上面' : '柱芯'
            @preview = PlanDimensions.endpoints([@refs.first, @hit.first], @anchors) if @refs.one?
          end
        end
        view.invalidate
      end

      def onLButtonDown(flags, x, y, view)
        onMouseMove(flags, x, y, view)
        return unless current?(view)

        if @refs.empty? && @hit
          @refs << @hit.first
          @first = @hit.last
          prompt
        elsif @refs.one? && @hit
          unless @preview && PlanDimensions.geometry(@preview, 0) && PlanDimensions.within_crop?(@preview, @crop)
            Sketchup.set_status_text('寸法の直角位置に仕上面がありません。別の壁面か柱芯を選んでください。', SB_PROMPT)
            return
          end

          @refs << @hit.first
          @points, @preview = @preview, nil
          prompt
        elsif @offset && @offset.abs >= 1 && PlanDimensions.within_crop?(@preview, @crop)
          complete({ 'id' => SecureRandom.uuid, 'refs' => @refs, 'offset' => @offset })
        end
      end

      def draw(view)
        return unless current?(view)

        view.drawing_color = Sketchup::Color.new(0, 157, 163)
        view.line_width = 2
        if @points && @preview
          a, b = @points
          u, v = @preview
          view.draw2d(GL_LINES, [a, u, u, v, v, b].map { |xy| pixel(view, xy) })
          midpoint = u.zip(v).map { |first, last| (first + last) / 2 }
          _, length, = PlanDimensions.geometry(@points, 0)
          view.draw_text(pixel(view, midpoint), format('%.1f mm', length))
        elsif @preview
          view.draw2d(GL_LINES, @preview.map { |xy| pixel(view, xy) })
        end
        point = @hit&.last || @first
        if point
          x, y = screen(view, point)
          marks = [[x - 5, y], [x + 5, y], [x, y - 5], [x, y + 5]]
          view.draw2d(GL_LINES, marks.map { |u, v| Geom::Point3d.new(u, v, 0) })
        end
      end

      private

      def screen(view, xy)
        point = view.screen_coords(API.point(*xy, @z))
        [point.x, point.y]
      end

      def pixel(view, xy)
        Geom::Point3d.new(*screen(view, xy), 0)
      end

      def prompt
        text = ['① 壁仕上面か柱芯をクリック。', '② もう一方の壁仕上面か柱芯をクリック。', '③ 寸法線を置く位置をクリック。'][@refs.size]
        Sketchup.set_status_text("#{text} Escで終了。", SB_PROMPT)
      end

      def complete(data)
        callback, @finish = @finish, nil
        @model.select_tool(nil) if data
        callback&.call(data)
      end
    end
  end
end
