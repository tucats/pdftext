# pdftext

I needed a quick tool that would help me quickly search PDF files that were composed of scanned
image pages (as opposed to PDF text elements). I can do this using Preview on a Mac, but  I
wanted a tool I could put in scripts and automations. I saw there are a number of tools out there
for money (or on somewhat _uncertain_ websites) and I wasn't happy with any of them, particularly.

However, an advantage of tools like Claude is that you can just write your own tool if you need to.

This tool was written entirely by Claude, based on a prompt describing the command line parameters
and the expectation that it would use Apple's Vision Framework to do the actual image recognition
and OCR work.

Claude took about 15 minutes to write and test the tool. I used it against an 800+ page manual that
I wanted to be able to search, and an M5 Pro chip can scan the entire manual into text in about
one minute (>20ppm).

If the PDF has text components, those are stripped to the output directly. If it contains OCR hints
(typically placed there by scanner software) it will use those unless you use the --ocr flag that
says just do it again -- I find many of the OCR hints placed by scanners predate modern machine
learning OCR techniques are are rough at best.

Like any OCR, this can make mistakes -- particularly true in some kinds of technical documentation.
For example it can confuse "P1" (pee-one) with "Pl" (pee-ell) in some cases... your mileage may
vary. But given that my goal was to build text indexes for the real PDF quickly, this turned out
to be a huge help.

Yours to use as you wish. Requires MacOS 15 or later, of course, since it depends on the Vision
Framework.
