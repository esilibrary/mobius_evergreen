BEGIN;

INSERT INTO config.org_unit_setting_type ( name, grp, label, description, datatype )
    VALUES (
        'extra.book_carousel.bookbags', 'opac',
        oils_i18n_gettext(
            'extra.book_carousel.bookbags',
            'Bookbags for book carousels',
            'coust', 'label'),
        oils_i18n_gettext(
            'extra.book_carousel.bookbags',
            'Comma-separated list of the numeric IDs of the bookbags to use for displaying book carousels',
            'coust', 'description'),
        'string'
    );

COMMIT;
