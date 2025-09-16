use bevy::prelude::*;
use bevy::camera::NormalizedRenderTarget;
use bevy::window::PrimaryWindow;

use crate::BlurRegion;
use crate::BlurRegionsCamera;

pub struct BlurRegionsBevyUiPlugin;

impl Plugin for BlurRegionsBevyUiPlugin {
    fn build(&self, app: &mut App) {
        app.add_systems(Last, crate::bevy_ui::compute_blur_regions);
    }
}

pub fn compute_blur_regions(
    nodes: Query<(&ComputedNode, &UiGlobalTransform, &BorderRadius, &ViewVisibility, Option<&crate::core::BlurRegionSettings>), With<BlurRegion>>,
    mut blur_regions_cameras: Query<(&Camera, &mut BlurRegionsCamera)>,
    primary_window: Query<Entity, With<PrimaryWindow>>,
    ui_scale: Res<UiScale>,
    windows: Query<&Window>,
) {
    for (camera, mut blur_regions) in &mut blur_regions_cameras {
        let Some(target) = camera.target.normalize(primary_window.single().ok()) else {
            continue;
        };

        let NormalizedRenderTarget::Window(window_entity) = target else {
            continue;
        };

        let Ok(window) = windows.get(window_entity.entity()) else {
            continue;
        };

        let viewport_size = window.size() / ui_scale.0;


        let mut sorted_nodes: Vec<_> = nodes.iter().collect();
        sorted_nodes.sort_by_key(|(node, ..)| node.stack_index);
        sorted_nodes.reverse();

        for (node, transform, border_radius, visibility, settings) in sorted_nodes {
            if visibility.get() == false && false {
                continue;
            }

            let region_settings = settings.copied().unwrap_or_default();

            let translation = transform.translation;
            let region = Rect::from_center_size(
                translation.xy(),
                node.size(),
            );
            let resolved = [
                border_radius.top_left,
                border_radius.top_right,
                border_radius.bottom_right,
                border_radius.bottom_left,
            ]
            .map(|v| v.resolve(window.scale_factor(), node.size().y, window.physical_size().as_vec2()).unwrap_or(0.0));
            blur_regions.rounded_blur(region, bevy::prelude::Vec4::from_array(resolved), region_settings);
        }
    }
}
