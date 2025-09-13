use bevy::prelude::*;
use bevy::render::extract_component::ExtractComponent;
use bevy::render::render_resource::ShaderType;

pub const DEFAULT_MAX_BLUR_REGIONS_COUNT: usize = 20;

/// Add this marker component to a UI Node to indicate that a blur region
/// should be created behind it.
#[derive(Component, Reflect, Default, Clone, Copy, PartialEq, Eq)]
#[reflect(Component, Default, PartialEq)]
pub struct BlurRegion;

#[derive(Component, Reflect, Clone, Copy)]
#[reflect(Component, Default)]
pub struct BlurRegionSettings {
    pub glass_brightness: f32,
    pub shadow_intensity: f32,
    pub rim_intensity: f32,
    pub rim_tightness: f32,
    pub black_opacity: f32,
    pub extra_brightness: f32,
    pub light_intensity: f32,
    pub displacement_falloff_start: f32,
    pub displacement_falloff_width: f32,
    pub specular_intensity: f32,
    pub reflection_shininess: f32,
}
impl Default for BlurRegionSettings {
    fn default() -> Self {
        Self {
            glass_brightness: 1.7,
            shadow_intensity: 0.2,
            rim_intensity: 0.2,
            rim_tightness: 2.5,
            black_opacity: 0.45,
            extra_brightness: 0.02,
            light_intensity: 5.0,
            displacement_falloff_start: 40. * 1.1,
            displacement_falloff_width: 70. * 1.1,
            specular_intensity: 3.,
            reflection_shininess: 5.,
        }
    }
}


/// The final computed values of the blur region, in physical pixels.
#[derive(Default, Debug, Clone, ShaderType)]
#[repr(C)]
pub struct ComputedBlurRegion {
    min_x: f32,
    max_x: f32,
    min_y: f32,
    max_y: f32,
    border_radii: Vec4,
    glass_brightness: f32,
    shadow_intensity: f32,
    rim_intensity: f32,
    rim_tightness: f32,
    black_opacity: f32,
    extra_brightness: f32,
    light_intensity: f32,
    displacement_falloff_start: f32,
    displacement_falloff_width: f32,
    pub specular_intensity: f32,
    pub reflection_shininess: f32,
}

impl ComputedBlurRegion {
    const OFFSCREEN: ComputedBlurRegion = ComputedBlurRegion {
        min_x: -1.0,
        max_x: -1.0,
        min_y: -1.0,
        max_y: -1.0,
        border_radii: Vec4::ZERO,

        glass_brightness: 0.0,
        shadow_intensity: 0.0,
        rim_intensity: 0.0,
        rim_tightness: 0.0,
        black_opacity: 0.0,
        extra_brightness: 0.0,
        light_intensity: 0.0,
        displacement_falloff_start: 0.0,
        displacement_falloff_width: 0.0,
        specular_intensity: 3.,
        reflection_shininess: 5.,
    };
}

//pub type DefaultBlurRegionsCamera = BlurRegionsCamera<DEFAULT_MAX_BLUR_REGIONS_COUNT>;

/// Indicates that this camera should render blur regions, as well as providing
/// settings for the blurring.
#[derive(Component, Debug, Clone, ExtractComponent)]
pub struct BlurRegionsCamera {
    /// The diameter of the circle of confusion around the current pixel that is being blurred.
    /// A larger diameter will make the image appear more blurry.
    /// In physical pixels.
    /// https://en.wikipedia.org/wiki/Circle_of_confusion
    pub circle_of_confusion: f32,
    pub regions: Vec<ComputedBlurRegion>,
}

impl Default for BlurRegionsCamera {
    fn default() -> Self {
        Self {
            circle_of_confusion: 50.0, // Or your preferred default blur strength
            regions: Vec::new(),
        }
    }
}

impl BlurRegionsCamera {
    pub fn blur(&mut self, rect: Rect, settings: BlurRegionSettings) {
        self.rounded_blur(rect, Vec4::ZERO, settings);
    }

    pub fn rounded_blur(&mut self, rect: Rect, border_radii: Vec4, settings: BlurRegionSettings) {
        self.regions.push(ComputedBlurRegion {
            min_x: rect.min.x,
            max_x: rect.max.x,
            min_y: rect.min.y,
            max_y: rect.max.y,
            border_radii,
            // NEW: Assign settings to the computed region.
            glass_brightness: settings.glass_brightness,
            shadow_intensity: settings.shadow_intensity,
            rim_intensity: settings.rim_intensity,
            rim_tightness: settings.rim_tightness,
            black_opacity: settings.black_opacity,
            extra_brightness: settings.extra_brightness,
            light_intensity: settings.light_intensity,
            displacement_falloff_start: settings.displacement_falloff_start,
            displacement_falloff_width: settings.displacement_falloff_width,
            specular_intensity: settings.specular_intensity,
            reflection_shininess: settings.reflection_shininess,
        });
    }

    pub fn blur_all(&mut self, rects: &[Rect], settings: BlurRegionSettings) {
        for rect in rects {
            self.blur(*rect, settings);
        }
    }

    pub fn rounded_blur_all(&mut self, rects: &[(Rect, Vec4, BlurRegionSettings)]) {
        for rect in rects {
            self.rounded_blur(rect.0, rect.1, rect.2);
        }
    }

    fn clear(&mut self) {
        self.regions.clear();
    }
}

fn clear_blur_regions(mut blur_region_cameras: Query<&mut BlurRegionsCamera>) {
    for mut blur_region in &mut blur_region_cameras {
        blur_region.clear();
    }
}

pub struct BlurRegionsPlugin;

impl Default for BlurRegionsPlugin {
    fn default() -> Self {
        BlurRegionsPlugin
    }
}

impl Plugin for BlurRegionsPlugin {
    fn build(&self, app: &mut App) {
        app.register_type::<BlurRegion>();
        app.register_type::<BlurRegionSettings>();
        app.add_systems(PreUpdate, clear_blur_regions)
            .add_plugins(crate::shader::BlurRegionsShaderPlugin);

        #[cfg(feature = "bevy_ui")]
        app.add_plugins(crate::bevy_ui::BlurRegionsBevyUiPlugin);

        #[cfg(feature = "egui")]
        app.add_plugins(crate::egui::BlurRegionsEguiPlugin);
    }
}