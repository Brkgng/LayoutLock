/// <reference types="@raycast/api">

/* 🚧 🚧 🚧
 * This file is auto-generated from the extension's manifest.
 * Do not modify manually. Instead, update the `package.json` file.
 * 🚧 🚧 🚧 */

/* eslint-disable @typescript-eslint/ban-types */

type ExtensionPreferences = {}

/** Preferences accessible in all the extension's commands */
declare type Preferences = ExtensionPreferences

declare namespace Preferences {
  /** Preferences accessible in the `restore-layout` command */
  export type RestoreLayout = ExtensionPreferences & {}
  /** Preferences accessible in the `save-current-layout` command */
  export type SaveCurrentLayout = ExtensionPreferences & {}
}
declare namespace Arguments {
  /** Arguments passed to the `restore-layout` command */
  export type RestoreLayout = {}
  /** Arguments passed to the `save-current-layout` command */
  export type SaveCurrentLayout = {
  /** Layout name (optional) */
  "name": string
}
}
