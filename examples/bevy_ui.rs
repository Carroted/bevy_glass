// Demonstrates how to use Bevy UI integration to blur nodes.
//   cargo run --example bevy_ui

use bevy::prelude::*;
use bevy_blur_regions::{prelude::*, BlurRegionSettings};

#[path = "./utils.rs"]
mod utils;

fn main() {
    App::new()
        .add_plugins(DefaultPlugins.set(WindowPlugin {
            primary_window: Some(Window {
                present_mode: bevy::window::PresentMode::AutoNoVsync,
                ..default()
            }),
            ..default()
        }))
        .add_plugins(BlurRegionsPlugin::default())
        .add_systems(Startup, setup)
        .add_systems(Startup, (utils::spawn_example_scene_3d))
        .add_systems(Update, move_node)
        .run();
}

#[derive(Component)]
struct MovingRegion;

fn setup(mut commands: Commands) {
    // 3D camera
    commands.spawn((
        BlurRegionsCamera::default(),
        Camera3d::default(),
        Camera { order: 1, ..default() },
        Transform::from_xyz(-2.5, 4.5, 9.0).looking_at(Vec3::ZERO, Vec3::Y),
    ));

    // UI camera
    commands.spawn((Camera2d::default(), Camera { order: 2, ..default() }));

    // UI node with blur region
    commands.spawn((
        BlurRegion,
        Node {
            width: Val::Px(800.0),
            height: Val::Px(1000.0),
            left: Val::Px(250.0),
            top: Val::Px(250.0),
            border: UiRect::all(Val::Px(5.0)),
            position_type: PositionType::Absolute,
            ..default()
        },
        MovingRegion,
        BlurRegionSettings {
            // opacity: 0.1,
            blur_only: 1.0,
            ..Default::default()
        },
        //BorderColor::all(Color::BLACK),
        //BorderRadius::new(Val::ZERO, Val::Percent(5.0), Val::Percent(10.0), Val::Percent(15.0)),
        BorderRadius::all(Val::Px(30.0)),
    ));

    // one that doesnt move
    commands.spawn((
        BlurRegion,
        Node {
            position_type: PositionType::Absolute,
            left: Val::Px(15.0),
            bottom: Val::Px(15.0),
            width: Val::Px(200.0),
            height: Val::Px(80.0),
            border: UiRect::all(Val::Px(5.0)),
            ..default()
        },
        BorderColor::all(Color::BLACK),
        BorderRadius::all(Val::Percent(50.0)),
    ));
}

// fn move_node(time: Res<Time>, mut nodes: Query<(&mut Node, &mut Visibility), With<MovingRegion>>) {
//     for (mut node, mut visibility) in &mut nodes {
//         node.left = Val::Percent((time.elapsed_secs().cos() + 1.0) / 2.0 * 50.0);
//         node.top = Val::Percent((time.elapsed_secs().sin() + 1.0) / 2.0 * 50.0);

//         *visibility = if time.elapsed_secs() % 2. < 1. {
//             Visibility::Visible
//         } else {
//             //Visibility::Hidden
//             Visibility::Visible
//         };
//     }
// }

// instead move with WASD
fn move_node(
    keyboard: Res<ButtonInput<KeyCode>>,
    time: Res<Time>,
    mut nodes: Query<(&mut Node, &mut ViewVisibility), With<MovingRegion>>,
) {
    let mut movement = Vec2::ZERO;
    if keyboard.pressed(KeyCode::KeyW) {
        movement.y -= 1.0;
    }
    if keyboard.pressed(KeyCode::KeyS) {
        movement.y += 1.0;
    }
    if keyboard.pressed(KeyCode::KeyA) {
        movement.x -= 1.0;
    }
    if keyboard.pressed(KeyCode::KeyD) {
        movement.x += 1.0;
    }
    if movement != Vec2::ZERO {
        movement = movement.normalize() * 500.0 * time.delta_secs();

        for (mut node, mut visibility) in &mut nodes {
            if let Val::Px(left) = node.left {
                node.left = Val::Px((left + movement.x));
            }
            if let Val::Px(top) = node.top {
                node.top = Val::Px((top + movement.y));
            }
        }
    }
}