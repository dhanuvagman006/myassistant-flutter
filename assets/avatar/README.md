# Assistant portraits (optional)

Drop licensed, photorealistic portraits here and the assistant face uses
them automatically — no code change required:

    assistant_female.jpg    shown when the user's profile gender is male
    assistant_male.jpg      shown when the user's profile gender is female
    assistant_neutral.jpg   used when gender is unknown/other

Guidance: square (1:1), >= 512x512, face centred and looking toward the
camera, neutral-to-warm expression, plain background.

No imagery is committed with the app: a photorealistic human face must be
a licensed asset (stock, or a provider such as Tavus), not something
generated in code. Until a file is present the assistant renders an
animated non-photographic "presence" instead — never the old microphone
icon.

The live path is Tavus (see backend src/avatar/tavus.js); when a live
avatar session is available its video frame takes priority over these
stills.
