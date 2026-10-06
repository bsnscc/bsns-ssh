# bsns.SSH launch plan

bsns.SSH should give people a useful tool and a reason to remember who built it.
The first job is to make connecting to their own machines easy. The connection
to bsns.cc can follow naturally once they have used the app.

## Who we should reach first

Start with developers and people who run their own servers, especially those
who use tmux and move between a Mac, iPad, and phone. They can try the app in a
few minutes, understand its tradeoffs, and tell us where it gets in their way.
Security-key users are a smaller second audience with specific requirements;
show the supported combinations rather than making a broad security claim.

Some users will run consultancies, agencies, or small businesses and have a
reason to explore bsns.cc. Many will only want an SSH client. Both are useful
outcomes. Downloads alone will not tell us whether the broader business gained
customers, and we should not assume a large conversion rate between these audiences.

## What to lead with

Lead with getting back to work from another device. Show an actual session
running on an always-on host, then open it from the phone. Show the keyboard
being hidden so the terminal becomes readable. Once shared workspace sync has
passed its device checks, show the same named windows on the Mac and iPad.

Explain the pieces plainly: tmux keeps the processes on the host; bsns.SSH is
how you reach them. The host must remain awake and reachable. Restoring a layout
after a host reboot does not restore the processes that were running in it.

Support that demonstration with three useful facts: the app is free and open
source, it supports hardware-backed keys, and it can encrypt configuration before
saving it to storage the user chooses. Each gives people something concrete to
inspect. Generic claims about being the best, most secure, or revolutionary add
nothing.

The public name remains **bsns.SSH**. In prose, introduce it as “bsns.SSH, a free
SSH and mosh client.” Keep “free and open source” close to the download link.
“Tools for Operators” can describe a future collection; it does not need to be
a second brand people must learn before trying this app.

## How bsns.cc should appear

Use a short “Built by bsns.cc” line in About, the repository, and the product
page. Give it a normal link someone can choose to follow. Keep connections,
key setup, and terminal sessions free of promotional interruptions.

Suggested copy for the product page:

> We use bsns.SSH while building bsns.cc, our software for running a small
> business. We made the SSH client available because other people might find
> it useful too. It is a separate, free tool; you do not need a bsns.cc account.

Follow that with “What we're building at bsns.cc.” The destination should
explain customers, work, scheduling, and invoicing in the language of a business
owner. The [current bsns.cc site](https://bsns.cc) already gives us that context.
Do not imply that SSH sessions connect to, depend on, or become part of the
business product.

## Copy for the product page

Create a dedicated SSH page, provisionally `tools.bsns.cc/ssh`, before the broad
launch. That path is a proposal, not an existing page. The tools site root
currently opens a domain checker; the staged store listing points to the SSH
repository until the product page is available.

**Opening:** Get back to your terminal.

**Introduction:** bsns.SSH is a free, open-source SSH and mosh client. Connect to
your own machines, use the keys you choose, and keep your setup with you.

**Primary action:** Download for iPhone and iPad.

**Other links:** Mac download, Android download, source code, and getting started.
Show a download action only when that platform has a tested, publicly available
artifact. Until then, show its actual availability without suggesting a release
has happened. The native Mac app and the iOS app running on an Apple-silicon Mac
are different distribution paths.

Put a short demonstration beside the introduction. Follow with a terminal
screenshot, a small section explaining keys and encrypted sync, installation
instructions, current limitations, and the bsns.cc line. Keep the source and
privacy links easy to find. The [store copy](store-listing.md) supplies the
platform-specific feature description.

## Founder introduction draft

> Most of my work on bsns.cc happens in terminal sessions on my own machines.
> I move between a Mac, an iPad, and a phone, and I want to get back to the work
> that's already running.
>
> That's how I use bsns.SSH. It's an SSH and mosh client with key management,
> SFTP, encrypted configuration sync, and a phone interface that lets me hide
> the keyboard when I need to read more of the terminal.
>
> It's free and open source. There are no ads or subscriptions, and you don't
> need a bsns.cc account. If this is how you work too, I'd like to hear what
> works for you and what doesn't.

Use this as an introduction the maintainer can edit, not a fabricated customer quote.
Pair it with a working download and source link when publishing.

## Demonstration and screenshots

Make a 45-second website video with readable captions and actual device footage.
Use a clean demo workspace with harmless files and terminal output. Do not show
personal hostnames, prompts containing private paths, credentials, or real work.

| Time | What to show | What the viewer should understand |
| --- | --- | --- |
| 0–8 seconds | A named tmux session on an always-on host, open from the Mac | The work is already running |
| 8–20 seconds | Open that host and session on the phone | The phone can reach the same work |
| 20–28 seconds | Hide the keyboard, read output, show it again | The terminal is usable on a small screen |
| 28–36 seconds | Browse and download a sample file | SFTP is included |
| 36–45 seconds | Show a hardware-backed key entry and download/source links | Key choice, availability, and where to try it |

Film cross-device workspace sync only after the physical-device test passes.
Keep a separate App Store preview to 30 seconds or less using footage from the
submitted platform, following [Apple's product-page guidance](https://developer.apple.com/app-store/product-page/).
A website film that cuts between devices is not automatically a suitable store preview.

Capture five current store screenshots, in this order:

1. A connected terminal with the phone keyboard hidden. Caption: “More room to read.”
2. Named sessions or workspaces. Caption: “Keep your hosts organized.”
3. The key list, with the actual key type visible. Caption: “Choose where your keys live.”
4. SFTP with the sample files. Caption: “Move a file without leaving the app.”
5. Encrypted configuration sync. Caption: “Keep your setup with you.”

Make separate iPhone and iPad sets. Show the relevant layout on each, rather
than stretching a phone image to fill a tablet. Existing store screenshots need
a visual review against the final build before reuse.

## Launch sequence

First finish the release checks and stage the listing for manual release. A
saved listing is not a submission, and a submission is not a public launch.
The review host, privacy work, and final candidate remain in the
[release checklist](launch-checklist.md).

Before announcing broadly, put the release in the hands of 5–10 people with
different setups: password login, software keys, hardware keys, tmux, and a
fresh configuration. This is a proposed testing group, not a claim that these
testers are already recruited. Ask where they got stuck, whether they could
read and control their session, and what they would miss from their usual setup.
Resolve broken first-use flows before spending effort on reach.

For launch, publish the working download page, matching source tag and release
notes, screenshots, and video together. Make a founder post with the concrete
example above. Then consider a Show HN submission while the maintainer is available to
answer questions. Its [guidelines](https://news.ycombinator.com/showhn.html) call
for something people can try, not a waitlist or an announcement page. Suggested
title: “Show HN: bsns.SSH, a free open-source SSH and mosh client.”

Over the following week, share a useful walkthrough in relevant server, tmux,
and mobile-development communities where their rules permit it. Tailor each
post to something that audience can do with the app. Check community rules at
posting time. Do not arrange votes, duplicate the same pitch everywhere, or
ask people for positive reviews.

Follow with two practical articles: using a phone to reconnect to work in tmux,
and choosing a key and setting up encrypted sync. These should be useful even
to someone who never buys anything from bsns.cc. Hold paid promotion until we
know people can get started and choose to keep using the app.

## What to measure

Review results weekly for the first month. Use aggregate store impressions and
downloads, optional platform usage reports where available, repository traffic,
issue themes, and voluntary feedback. Platform reports can have consent and
sample-size limits; they do not give us a complete view of app use.

Keep the app free of tracking SDKs. For the brand connection, review aggregate
visits from the product page to bsns.cc using the site's existing lawful
measurement, if available, and ask interested businesses how they found us.
Do not introduce device identifiers or connect a person's terminal activity to
a marketing profile. An optional campaign parameter on a web link identifies
the link's source, not an individual app installation.

The first useful signals are people completing setup, returning to the app,
recommending it without prompting, and raising issues we can fix. A few
qualified business conversations are worth recording separately from downloads
and repository stars. Set numerical targets after the first baseline, rather
than inventing a conversion forecast now.

## Editorial rules

Write like someone explaining a tool they use. Prefer specific actions and
examples. Use first person only for the maintainer's own experience. Read public copy
aloud and remove wording that would sound strange in a conversation.

Do not use invented testimonials, inflated security promises, generic superlatives,
or a string of slogans in place of an explanation. Avoid stock phrases such as
“seamless,” “unlock,” “game-changing,” and “built for modern teams.” Say “no
analytics SDK” when that is the verified claim; do not turn it into “no data ever
leaves your device.” Explain optional cloud features where they matter.

Before any public announcement, check every feature against the named release,
verify all download links, and read the copy once more with the screenshots next
to it. A feature that is planned or available on a different platform should not
appear as something a new user will get immediately.
