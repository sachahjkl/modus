package modustool

import "core:fmt"
import "core:os"
import "core:strings"
import "modustool:foundation"

// The download section of the home and of the page of the releases: the
// files of the newest release, the release signing key, and the steps that
// verify the files (src/md/infrastructure/release_image.md).

// The public key of the release signing key in the site, in its two forms:
// the text of the repository, and PEM for OpenSSL.
SITE_RELEASE_KEY_FILE :: RELEASE_SIGNING_KEY_FILE_NAME + SIGNING_KEY_PUBLIC_SUFFIX
SITE_RELEASE_KEY_PEM_FILE :: RELEASE_SIGNING_KEY_FILE_NAME + ".pem"
// The certificate of the firmware signing key, in PEM and in DER: the
// setup of a firmware reads one or the other.
SITE_FIRMWARE_CERTIFICATE_PEM_FILE :: FIRMWARE_CERTIFICATE_FILE_NAME
SITE_FIRMWARE_CERTIFICATE_DER_FILE :: "firmware_signing_key.cer"
SITE_INSTALL_GUIDE :: "docs/INSTALL.md"
SITE_INSTALL_VERIFY_HEADING :: "2. Verify the files"

// site_publisher_key_files_write reads the public key of the release
// signing key and the certificate of the firmware signing key of the
// repository, and writes their forms in the site. A repository with no
// release signing key has published no image: the section says so. A file
// of another form stops the command.
site_publisher_key_files_write :: proc(site: ^Site) -> bool {
	site.release_public_key = ""
	site.firmware_certificate_present = false
	if data, read_error := os.read_entire_file(RELEASE_PUBLIC_KEY_FILE, context.temp_allocator); read_error == nil {
		public_key, valid := release_key_decode(string(data))
		if !valid {
			fmt.eprintfln("modustool: site: %s must hold the 32 bytes of a public key in base64url with no padding", RELEASE_PUBLIC_KEY_FILE)
			return false
		}
		site.release_public_key = base64url_text(public_key[:])
		key_line := strings.concatenate({site.release_public_key, "\n"}, context.temp_allocator)
		site_write_file(site, SITE_RELEASE_KEY_FILE, transmute([]u8)key_line) or_return
		site_write_file(site, SITE_RELEASE_KEY_PEM_FILE, transmute([]u8)release_public_key_pem(public_key)) or_return
	}
	if certificate, read_error := os.read_entire_file(RELEASE_FIRMWARE_CERTIFICATE_FILE, context.temp_allocator); read_error == nil {
		certificate_bytes, valid := pem_body_bytes(string(certificate))
		if !valid {
			fmt.eprintfln("modustool: site: %s must be a certificate in PEM", RELEASE_FIRMWARE_CERTIFICATE_FILE)
			return false
		}
		site_write_file(site, SITE_FIRMWARE_CERTIFICATE_PEM_FILE, certificate) or_return
		site_write_file(site, SITE_FIRMWARE_CERTIFICATE_DER_FILE, certificate_bytes) or_return
		site.firmware_certificate_present = true
	}
	return true
}

// site_download_write writes the download section: the three files of the
// newest release with their links on the releases of the repository, the
// release signing key, and the command that verifies them.
site_download_write :: proc(site: ^Site, b: ^strings.Builder, from_page: string) {
	strings.write_string(b, "<section class=\"card accent-boot download\" aria-labelledby=\"download\">\n<h2 id=\"download\">Download</h2>\n")
	// With no key, no file exists: one line, and no steps for files that do
	// not exist.
	if site.release_public_key == "" {
		strings.write_string(b, "<p>No release publishes a disk image yet.</p>\n</section>\n")
		return
	}
	// The band above the card, or the heading of the release below it,
	// gives the release number, and each link holds the tag: the list
	// alone says what each file is.
	tag := strings.concatenate({"v", site.release}, context.temp_allocator)
	address := strings.concatenate({SITE_REPOSITORY_ADDRESS, "/releases/download/", tag, "/"}, context.temp_allocator)
	image_name := release_image_file_name(site.release)
	strings.write_string(b, "<ul class=\"download-files\">\n")
	Download_File :: struct {
		name, what: string,
	}
	download_files := [?]Download_File {
		{image_name, "the disk image, compressed with zstd"},
		{RELEASE_CHECKSUM_FILE_NAME, "the SHA-256 of the image, in the form of sha256sum"},
		{RELEASE_CHECKSUM_FILE_NAME + RELEASE_SIGNATURE_SUFFIX, "the release signature of the checksum list"},
	}
	for file in download_files {
		strings.write_string(b, "<li><a href=\"")
		foundation.site_escape(b, address)
		foundation.site_escape(b, file.name)
		strings.write_string(b, "\"><code>")
		foundation.site_escape(b, file.name)
		strings.write_string(b, "</code></a>: ")
		foundation.site_escape(b, file.what)
		strings.write_string(b, "</li>\n")
	}
	strings.write_string(b, "</ul>\n<p>The release signing key: <code class=\"download-key\">")
	foundation.site_escape(b, site.release_public_key)
	strings.write_string(b, "</code> (<a href=\"")
	foundation.site_escape(b, site_page_link(site, from_page, SITE_RELEASE_KEY_FILE))
	strings.write_string(b, "\">text</a>, <a href=\"")
	foundation.site_escape(b, site_page_link(site, from_page, SITE_RELEASE_KEY_PEM_FILE))
	strings.write_string(b, "\">PEM</a>).</p>\n")
	if site.firmware_certificate_present {
		strings.write_string(b, "<p>The certificate of the firmware signing key, which the firmware needs for Secure Boot: <a href=\"")
		foundation.site_escape(b, site_page_link(site, from_page, SITE_FIRMWARE_CERTIFICATE_DER_FILE))
		strings.write_string(b, "\">DER</a>, <a href=\"")
		foundation.site_escape(b, site_page_link(site, from_page, SITE_FIRMWARE_CERTIFICATE_PEM_FILE))
		strings.write_string(b, "\">PEM</a>.</p>\n")
	}
	strings.write_string(b, "<p>Verify the files before you write the USB key:</p>\n<pre><code>nix develop -c modustool verify ")
	foundation.site_escape(b, image_name)
	strings.write_string(b, " ")
	foundation.site_escape(b, RELEASE_CHECKSUM_FILE_NAME)
	strings.write_string(b, "</code></pre>\n")
	site_download_guide_line(site, b, from_page)
	strings.write_string(b, "</section>\n")
}

// site_download_guide_line writes the line that names the guide of the
// install: the steps with OpenSSL and sha256sum, the USB key, the firmware.
site_download_guide_line :: proc(site: ^Site, b: ^strings.Builder, from_page: string) {
	strings.write_string(b, "<p>The steps with no tool, the USB key and the setting of the firmware: ")
	if !site_home_guide_link(site, b, from_page, SITE_INSTALL_GUIDE, SITE_INSTALL_VERIFY_HEADING) {
		strings.write_string(b, "<code>")
		foundation.site_escape(b, SITE_INSTALL_GUIDE)
		strings.write_string(b, "</code>")
	}
	strings.write_string(b, ".</p>\n")
}
