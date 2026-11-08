# Web Pages

Shell can show web pages next to your terminals. A page can load directly, or through one of your servers: then
`localhost` is the server's localhost, carried over SSH. That's handy for a development server or an admin page that
only listens on the server itself.

## Open a page

- Tap **+** on the **Web** header (**New Web Session**) for a blank page.
- Choose **Web Session** in a server's menu, or from the **+** on a connected server's row, for a page through that
  server.

A blank page reads "Type the page's address into the URL field, then press Return." Type the address in the URL field
of the title bar and press Return. You can type a bare name: Shell adds `https://`. The page names itself after its
title.

## Pages through a server

For a page through a server, Shell opens a tunnel to the server first ("Opening the tunnel to …"), then loads the page
through it. Type the address as the server sees it, for example `http://localhost:8000`. If nothing answers there, the
page shows **Couldn't Connect** with the reason.

On the Mac, the title bar has an SSH tunnel menu to pick the server, or none.

## Manage a page

Touch and hold (or right-click) a page:

- **Open**: shows it.
- **Reconnect**: closes the page and opens it again.
- **Edit…**: the **Edit Web Session** sheet, with **Name** (empty takes the page's title), **URL** and **SSH Host**
  (**None (open directly)** or one of your servers). Tap **Save**.
- **Delete**: removes the page.

Drag pages to reorder them. A page's row has a green dot while it's open.

Web pages are kept on this device only. They don't sync.

On Windows, Shell has no built-in web view: **Open in Browser** opens the page in your browser.
