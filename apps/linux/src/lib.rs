// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! The Linux client's transport and desktop integration, testable without a GPU.

pub mod account_state;
pub mod chat;
#[cfg(unix)]
pub mod client;
pub mod commands;
pub mod confirmation;
pub mod design;
pub mod desktop_data;
pub mod devices;
pub mod display;
pub mod drafts;
pub mod home;
pub mod insights;
pub mod integration;
pub mod layout;
pub mod localization;
pub mod menus;
pub mod navigation;
pub mod project_edit;
pub mod project_menu;
pub mod sidebar;
pub mod text_input;
pub mod work;

#[cfg(all(feature = "gui", any(target_os = "linux", target_os = "macos")))]
pub mod presentation;

#[cfg(all(feature = "gui", any(target_os = "linux", target_os = "macos")))]
pub mod symbols;

#[cfg(all(feature = "gui", any(target_os = "linux", target_os = "macos")))]
pub mod desktop;
#[cfg(all(feature = "gui", any(target_os = "linux", target_os = "macos")))]
mod input_field;

#[cfg(test)]
#[path = "../build_support/swift_contract.rs"]
mod swift_contract_tests;
