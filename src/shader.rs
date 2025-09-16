use bevy::asset::load_internal_asset;
use bevy::asset::uuid::Uuid;
use bevy::core_pipeline::core_2d::graph::Core2d;
use bevy::core_pipeline::core_2d::graph::Node2d;
use bevy::core_pipeline::core_3d::graph::Core3d;
use bevy::core_pipeline::core_3d::graph::Node3d;
use bevy::core_pipeline::FullscreenShader;
use bevy::ecs::query::QueryItem;
use bevy::ecs::system::lifetimeless::Read;
use bevy::prelude::*;
use bevy::render::extract_component::ComponentUniforms;
use bevy::render::extract_component::ExtractComponentPlugin;
use bevy::render::extract_component::UniformComponentPlugin;
use bevy::render::render_graph::NodeRunError;
use bevy::render::render_graph::RenderGraphContext;
use bevy::render::render_graph::RenderGraphExt;
use bevy::render::render_graph::RenderLabel;
use bevy::render::render_graph::ViewNode;
use bevy::render::render_graph::ViewNodeRunner;
use bevy::render::render_resource::binding_types::sampler;
use bevy::render::render_resource::binding_types::texture_2d;
use bevy::render::render_resource::binding_types::uniform_buffer;
use bevy::render::render_resource::AddressMode;
use bevy::render::render_resource::BindGroupEntries;
use bevy::render::render_resource::BindGroupLayout;
use bevy::render::render_resource::BindGroupLayoutEntries;
use bevy::render::render_resource::BlendState;
use bevy::render::render_resource::CachedRenderPipelineId;
use bevy::render::render_resource::ColorTargetState;
use bevy::render::render_resource::ColorWrites;
use bevy::render::render_resource::FragmentState;
use bevy::render::render_resource::MultisampleState;
use bevy::render::render_resource::Operations;
use bevy::render::render_resource::PipelineCache;
use bevy::render::render_resource::PrimitiveState;
use bevy::render::render_resource::RenderPassColorAttachment;
use bevy::render::render_resource::RenderPassDescriptor;
use bevy::render::render_resource::RenderPipelineDescriptor;
use bevy::render::render_resource::Sampler;
use bevy::render::render_resource::SamplerBindingType;
use bevy::render::render_resource::SamplerDescriptor;
use bevy::render::render_resource::ShaderStages;
use bevy::render::render_resource::ShaderType;
use bevy::render::render_resource::SpecializedRenderPipeline;
use bevy::render::render_resource::SpecializedRenderPipelines;
use bevy::render::render_resource::TextureFormat;
use bevy::render::render_resource::TextureSampleType;
use bevy::render::renderer::RenderContext;
use bevy::render::renderer::RenderDevice;
use bevy::render::view::ExtractedView;
use bevy::render::view::ViewTarget;
use bevy::render::Render;
use bevy::render::RenderApp;
use bevy::render::RenderSet;
use bevy::shader::ShaderDefVal;

use bevy::render::render_resource::{
    binding_types::{storage_buffer_read_only},
    StorageBuffer, UniformBuffer,
};
use bevy::render::renderer::RenderQueue;
use crate::core::ComputedBlurRegion;

#[derive(ShaderType, Default, Clone)]
struct GpuBlurRegionsSettings {
    circle_of_confusion: f32,
    regions_count: u32,
}

#[derive(Resource, Default)]
struct BlurRegionsBuffers {
    settings: UniformBuffer<GpuBlurRegionsSettings>,
    regions: StorageBuffer<Vec<ComputedBlurRegion>>,
}

use crate::BlurRegionsCamera;

fn get_shader_handle() -> Handle<Shader> {
    Handle::Uuid(Uuid::from_u128(271147050642476932735403127655134602927), std::marker::PhantomData::default())
}

fn blur_shader_handle() -> Handle<Shader> {
    Handle::Uuid(Uuid::from_u128(23994640822013354325), std::marker::PhantomData::default())
}
fn id_pass_shader_handle() -> Handle<Shader> {
    Handle::Uuid(Uuid::from_u128(30310243611322543265), std::marker::PhantomData::default())
}

pub struct BlurRegionsShaderPlugin;

impl Plugin for BlurRegionsShaderPlugin {
    fn build(&self, app: &mut App) {
        load_internal_asset!(app, get_shader_handle(), "carroted_glass.wgsl", Shader::from_wgsl);

        app.add_plugins(ExtractComponentPlugin::<BlurRegionsCamera>::default());

        let Some(render_app) = app.get_sub_app_mut(RenderApp) else {
            return;
        };

        render_app
        .init_resource::<SpecializedRenderPipelines<BlurRegionsPipeline>>()
        .init_resource::<BlurRegionsBuffers>()
        .add_systems(
            Render,
            (
                prepare_blur_regions_pipelines.in_set(RenderSet::Prepare),
                prepare_blur_regions_buffers.in_set(RenderSet::PrepareBindGroups),
            ),
        )
            .add_render_graph_node::<ViewNodeRunner<BlurRegionsNode>>(Core3d, BlurRegionsLabel)
            .add_render_graph_edges(Core3d, (Node3d::Tonemapping, BlurRegionsLabel, Node3d::Smaa))
            .add_render_graph_edges(Core3d, (BlurRegionsLabel, Node3d::Fxaa))
            .add_render_graph_node::<ViewNodeRunner<BlurRegionsNode>>(Core2d, BlurRegionsLabel)
            .add_render_graph_edges(Core2d, (Node2d::Tonemapping, BlurRegionsLabel, Node2d::Smaa))
            .add_render_graph_edges(Core2d, (BlurRegionsLabel, Node2d::Fxaa));
    }

    fn finish(&self, app: &mut App) {
        let Some(render_app) = app.get_sub_app_mut(RenderApp) else {
            return;
        };

        let render_device = render_app.world().resource::<RenderDevice>().clone();
        let fullscreen_shader = render_app.world().resource::<FullscreenShader>().clone();
        render_app.insert_resource(BlurRegionsPipeline::new(
            render_device,
            fullscreen_shader,
        ));
    }
}

fn prepare_blur_regions_pipelines(
    mut commands: Commands,
    pipeline_cache: Res<PipelineCache>,
    mut pipelines: ResMut<SpecializedRenderPipelines<BlurRegionsPipeline>>,
    pipeline: Res<BlurRegionsPipeline>,
    views: Query<(Entity, &ExtractedView), With<BlurRegionsCamera>>,
) {
    for (entity, view) in &views {
        let horizontal_pass = BlurRegionsPass {
            pass_label: "blur_regions_horizontal_pass",
            bind_group_label: "blur_regions_bind_group_horizontal",
            pipeline: pipelines.specialize(
                &pipeline_cache,
                &pipeline,
                BlurRegionsPipelineKey {
                    pass: BlurRegionsPassKey::Horizontal,
                    hdr: view.hdr,
                },
            ),
        };

        let vertical_pass = BlurRegionsPass {
            pass_label: "blur_regions_vertical_pass",
            bind_group_label: "blur_regions_bind_group_vertical",
            pipeline: pipelines.specialize(
                &pipeline_cache,
                &pipeline,
                BlurRegionsPipelineKey {
                    pass: BlurRegionsPassKey::Vertical,
                    hdr: view.hdr,
                },
            ),
        };

        commands.entity(entity).insert(BlurRegionsPasses([horizontal_pass, vertical_pass]));
    }
}

#[derive(Debug, Hash, PartialEq, Eq, Clone, RenderLabel)]
pub struct BlurRegionsLabel;

#[derive(Default)]
pub struct BlurRegionsNode;

impl ViewNode for BlurRegionsNode {
    type ViewQuery = (Read<ViewTarget>, Read<BlurRegionsPasses>);

    fn run(
        &self,
        _graph: &mut RenderGraphContext,
        render_context: &mut RenderContext,
        (view_target, passes): QueryItem<Self::ViewQuery>,
        world: &World,
    ) -> Result<(), NodeRunError> {
        let pipeline_cache = world.resource::<PipelineCache>();
        let blur_regions_pipeline = world.resource::<BlurRegionsPipeline>();

        let buffers = world.resource::<BlurRegionsBuffers>();

        if buffers.regions.get().is_empty() {
            return Ok(());
        }

        let Some(settings_binding) = buffers.settings.binding() else { return Ok(()); };
        let Some(regions_binding) = buffers.regions.binding() else { return Ok(()); };

        for pass in &passes.0 {
            let Some(pass_pipeline) = pipeline_cache.get_render_pipeline(pass.pipeline) else { continue; };

            let post_process = view_target.post_process_write();

            let bind_group = render_context.render_device().create_bind_group(
                pass.bind_group_label,
                &blur_regions_pipeline.layout,
                &BindGroupEntries::sequential((
                    post_process.source,
                    &blur_regions_pipeline.sampler,
                    settings_binding.clone(),
                    regions_binding.clone(),
                )),
            );
            
            let mut render_pass = render_context.begin_tracked_render_pass(RenderPassDescriptor {
                label: Some(pass.pass_label),
                color_attachments: &[Some(RenderPassColorAttachment {
                    view: post_process.destination,
                    resolve_target: None,
                    ops: Operations::default(),
                    depth_slice: None,
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
            });

            render_pass.set_render_pipeline(pass_pipeline);
            render_pass.set_bind_group(0, &bind_group, &[]);
            render_pass.draw(0..3, 0..1);
        }

        Ok(())
    }
}

#[derive(Resource)]
pub struct BlurRegionsPipeline {
    layout: BindGroupLayout,
    sampler: Sampler,
    fullscreen_shader: FullscreenShader,
}

impl BlurRegionsPipeline {
    fn new(render_device: RenderDevice, fullscreen_shader: FullscreenShader) -> Self {
        let layout = render_device.create_bind_group_layout(
            "blur_regions_bind_group_layout",
            &BindGroupLayoutEntries::sequential(
                ShaderStages::FRAGMENT,
                (
                    texture_2d(TextureSampleType::Float { filterable: true }),
                    sampler(SamplerBindingType::Filtering),
                    uniform_buffer::<GpuBlurRegionsSettings>(false),
                    storage_buffer_read_only::<ComputedBlurRegion>(false),
                ),
            ),
        );
        let sampler = render_device.create_sampler(&SamplerDescriptor {
            address_mode_u: AddressMode::MirrorRepeat,
            address_mode_v: AddressMode::MirrorRepeat,
            ..default()
        });

        Self { layout, sampler, fullscreen_shader, }
    }
}

#[derive(Component)]
pub struct BlurRegionsPasses([BlurRegionsPass; 2]);

pub struct BlurRegionsPass {
    pass_label: &'static str,
    bind_group_label: &'static str,
    pipeline: CachedRenderPipelineId,
}

#[derive(PartialEq, Eq, Hash, Clone, Copy)]
pub enum BlurRegionsPassKey {
    Horizontal,
    Vertical,
}

#[derive(PartialEq, Eq, Hash, Clone, Copy)]
pub struct BlurRegionsPipelineKey {
    pass: BlurRegionsPassKey,
    hdr: bool,
}
fn prepare_blur_regions_buffers(
    mut buffers: ResMut<BlurRegionsBuffers>,
    render_device: Res<RenderDevice>,
    render_queue: Res<RenderQueue>,
    cameras: Query<&BlurRegionsCamera>,
) {
    let Some(camera) = cameras.iter().next() else {
        // If no camera exists with the component, ensure the buffer is empty.
        if !buffers.regions.get().is_empty() {
            buffers.regions.get_mut().clear();
            buffers.regions.write_buffer(&render_device, &render_queue);
        }
        return;
    };

    // Write settings to the uniform buffer
    let settings = GpuBlurRegionsSettings {
        circle_of_confusion: camera.circle_of_confusion,
        regions_count: camera.regions.len() as u32,
    };
    buffers.settings.set(settings);
    buffers.settings.write_buffer(&render_device, &render_queue);

    // Write all region data to the storage buffer
    buffers.regions.set(camera.regions.clone());
    buffers.regions.write_buffer(&render_device, &render_queue);
}

impl SpecializedRenderPipeline for BlurRegionsPipeline {
    type Key = BlurRegionsPipelineKey;

    fn specialize(&self, key: Self::Key) -> RenderPipelineDescriptor {
        RenderPipelineDescriptor {
            label: Some("blur_regions_pipeline".into()),
            layout: vec![self.layout.clone()],
            vertex: self.fullscreen_shader.to_vertex_state(),
            primitive: PrimitiveState::default(),
            depth_stencil: None,
            multisample: MultisampleState::default(),
            push_constant_ranges: vec![],
            fragment: Some(FragmentState {
                shader: get_shader_handle(),
                shader_defs: vec![],
                entry_point: match key.pass {
                    BlurRegionsPassKey::Horizontal => Some("horizontal".into()),
                    BlurRegionsPassKey::Vertical => Some("vertical".into()),
                },
                targets: vec![Some(ColorTargetState {
                    format: if key.hdr {
                        ViewTarget::TEXTURE_FORMAT_HDR
                    } else {
                        TextureFormat::bevy_default()
                    },
                    blend: Some(BlendState::ALPHA_BLENDING),
                    write_mask: ColorWrites::ALL,
                })],
            }),
            zero_initialize_workgroup_memory: false,
        }
    }
}
