# Native interface design

Talkie Preview is a macOS utility for dictation, insertion and recovery. Native task structure, readable state and keyboard focus take priority over decoration.

## App presence

The original locally generated icon appears in the Dock and Command–Tab by default. **Settings → General → Show Talkie in Dock** offers menu-bar-only operation. Closing a window keeps the app running, and reopening from the Dock returns to the Library.

The menu-bar popover remains available in either mode. It shows actual app state, microphone selection, the selected shortcut, recent takes and access to the Library and Settings. Recording from the popover saves a note; shortcut dictation targets the user's external field.

## Recording overlay

The overlay is a nonactivating 212 × 44 pt capsule inside a 228 × 60 pt panel, centred near the active display's visible bottom edge. Its compact layout keeps the target field in view.

- While recording: microphone state, actual input level, elapsed time and Stop.
- While preparing or recognising: a progress indicator and a short processing label.
- After completion: a delivery or recovery receipt, with Copy when text is available and access to the Library.
- When capture needs review: an orange warning state with the full explanation available through help and accessibility text.
- When input is too quiet or no speech is recognised: a brief notice, with the recording retained in the Library and the app ready for the next dictation.

On macOS 26 and later the capsule uses native Liquid Glass. Earlier systems use native material. Reduce Transparency or increased contrast uses an opaque system surface and visible border; Reduce Motion suppresses animation. The panel must not take keyboard focus from the dictation destination.

## Library and Settings

The Library uses a native source list, chronological take list and readable transcript pane. Copying, pinning, playback, retry and deletion remain visible actions. Original recognition, approved corrections and deliberately applied frames remain distinct.

Settings groups General, Microphone, Speech model and Privacy & storage in native forms. Shortcut recording, Dock visibility, activation mode, cue controls, permissions, input testing and model state use ordinary macOS controls and disabled/loading/error states.

General settings offers the bundled activation chime or a custom local audio file, plus volume, Preview and **Use default** controls. The chooser explains the 10-second and 5 MB limits. The cue plays once the microphone is ready; its enabled state remains optional. Choosing audio keeps a managed copy in the preview's isolated data folder.

The interface follows light and dark appearance using semantic system colours, SF typography and a restrained orange accent. Monospaced digits are used for elapsed time and measurements.

## State must remain truthful

The UI distinguishes saved text, confirmed insertion, an unverified paste attempt and recovery requiring review. Repeated PCM is a capture-quality warning rather than a reason to cut a take short. Recording continues and the captured audio is preserved. Local recognition can save a draft from audible suspect input, labelled for review without automatic insertion; Library Retry retains the warning. The interface does not claim that a guard can repair an input stream or reconstruct missing words.

Quiet-input and no-speech outcomes return to idle after a short overlay notice rather than blocking the next dictation with an alert. Their recording and recovery status remain in the Library. Unexpected model or storage failures still receive an error alert so a recovery problem is not hidden.

The repository's vector overview uses synthetic text. It is an illustration of the product, not a live screenshot or evidence of microphone, insertion or Dock behavior. Source is the implementation authority; running-preview acceptance remains separate from illustration and automated checks.
